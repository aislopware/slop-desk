//! DIALOG-EXPAND: the capture region is the streamed window ∪ the panels the OS attached to it.
//!
//! A file-open, print or share dialog is a SEPARATE window that the window server attributes to the
//! host app's own pid — HW-verified: a Chrome file dialog enumerates as `pid == Chrome, layer == 0,
//! name == "Open"`. Capturing the window frame alone crops it, so the region grows to enclose the
//! panel and shrinks back when it closes. Everything here is pure: the caller supplies the window
//! records `rust/slopdesk-apple-cgwindow` read and the display the window sits on.
//!
//! ## Why the guards are spelled `!(x > 0.0)`
//!
//! Every skip test below is a NEGATED positive compare rather than the `<=` that reads better,
//! because the two differ on NaN and the difference is the whole point: an area that is NaN must
//! SKIP (the overlap fraction is undefined, so no panel qualifies) rather than pass through as
//! "not greater than zero, therefore small". `golden/golden_vectors.json` pins these outputs as raw
//! `f64` bit patterns, so the distinction is checked rather than trusted.
//!
//! The multiplies stay separate for the same reason — `a * b` then a compare, never a `mul_add`.
//! See `geometry`'s module header for the crate's float policy.

use crate::geometry::VideoRect;
use crate::video_control::MaskRect;

/// Minimum overlap fraction, of the SMALLER rect's area, for an attached panel.
///
/// Below it the overlap is incidental — a sibling window happening to touch — and unioning it would
/// drag the capture region across the desktop.
pub const DEFAULT_MIN_OVERLAP_FRACTION: f64 = 0.30;

/// Per-edge hysteresis threshold, in points. Each region change is an encoder rebuild and an IDR,
/// so a drift smaller than this is not worth the flicker.
pub const DEFAULT_MIN_DELTA: f64 = 8.0;

/// Whether a CG window level counts as ATTACHED to the streamed window.
///
/// `0` (`kCGNormalWindowLevel`) is a file/save/print sheet or dialog, attributed to the app's own
/// pid. `101` (`kCGPopUpMenuWindowLevel`) is a pop-up, context or dropdown menu that renders as a
/// separate same-pid window and can overhang the streamed one — HW-measured: VS Code's gear
/// "Manage" menu enumerates at layer `101`.
///
/// Deliberately EXCLUDES the menu bar (`24`), the Dock (`20`) and tooltips or status windows
/// (`25`): system chrome, or transient. Unioning them would drag the crop onto the top strip, or
/// churn the encoder open and closed on every hover.
#[must_use]
pub const fn is_associatable_layer(layer: i32) -> bool {
    layer == 0 || layer == 101
}

/// One on-screen window, as the window server described it — CG global points, top-left origin.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowSnapshot {
    /// The `CGWindowID`. Per-boot and reusable, so it names a window only alongside `owner_pid`.
    pub window_id: u32,
    /// The owning process. Association is BY PID: that is what makes a dialog "this window's".
    pub owner_pid: i32,
    /// The CG window level. See [`is_associatable_layer`].
    pub layer: i32,
    /// Where it sits.
    pub frame: VideoRect,
}

/// Whether `window` is a panel attached to the target: a DIFFERENT window, the SAME pid, on an
/// associatable layer, overlapping by at least `min_overlap_fraction` of the SMALLER area.
///
/// `target_area` is passed in rather than recomputed because the caller has already screened it for
/// positivity, and re-deriving it per window would repeat a multiply the golden vectors pin.
fn is_attached_panel(
    window: &WindowSnapshot,
    target_frame: VideoRect,
    target_window_id: u32,
    target_pid: i32,
    target_area: f64,
    min_overlap_fraction: f64,
) -> bool {
    if window.window_id == target_window_id
        || window.owner_pid != target_pid
        || !is_associatable_layer(window.layer)
    {
        return false;
    }
    // Null is a real GAP. An edge touch or a zero-area overlap is not null, and falls to the
    // fraction test below, which is where it belongs.
    let overlap = window.frame.intersection(&target_frame);
    if overlap.is_null() {
        return false;
    }
    // Each product is a SEPARATE multiply — never fused with the divide that follows.
    let overlap_area = overlap.width() * overlap.height();
    let window_area = window.frame.width() * window.frame.height();
    // A NaN-faithful minimum: the ternary answers NaN when the left side is NaN, which
    // `f64::min` would swallow. The skip guard below then catches it.
    let smaller_area = if window_area < target_area {
        window_area
    } else {
        target_area
    };
    // Both compares are POSITIVE, which is what makes them NaN-faithful without a negation: a NaN
    // area or a NaN fraction answers false, and false here is "not a panel". `>=` is inclusive, so
    // an overlap of exactly the fraction qualifies.
    smaller_area > 0.0 && overlap_area / smaller_area >= min_overlap_fraction
}

/// The capture region: `target_frame` ∪ every attached panel in `windows_in_front`, clamped to
/// `display_bounds`.
///
/// `windows_in_front` is front-to-back and strictly IN FRONT of the target — the slice
/// `slopdesk_cgwindow_in_front_of` answers. The whole panel frame joins the union even where it
/// overhangs the window, which is the point: the overhang is what was being cropped.
///
/// A target with zero or NaN area answers the clamped frame and nothing else, since the overlap
/// fraction every panel is judged by would be undefined.
#[must_use]
pub fn union_region(
    target_frame: VideoRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: &[WindowSnapshot],
    display_bounds: VideoRect,
    min_overlap_fraction: f64,
) -> VideoRect {
    // A SEPARATE multiply — see the module header.
    let target_area = target_frame.width() * target_frame.height();
    #[expect(
        clippy::neg_cmp_op_on_partial_ord,
        reason = "a NaN area must fall back to the clamped frame, which `<= 0.0` would not do"
    )]
    if !(target_area > 0.0) {
        return target_frame.intersection(&display_bounds);
    }
    let mut union = target_frame;
    for window in windows_in_front {
        if is_attached_panel(
            window,
            target_frame,
            target_window_id,
            target_pid,
            target_area,
            min_overlap_fraction,
        ) {
            union = union.union(&window.frame);
        }
    }
    let clamped = union.intersection(&display_bounds);
    if clamped.is_null() {
        target_frame.intersection(&display_bounds)
    } else {
        clamped
    }
}

/// The OPAQUE content rectangles inside the capture region: the target frame, then each attached
/// panel, every one clamped to `display_bounds` and any that clamps to nothing dropped.
///
/// Same qualification rule as [`union_region`], but the INDIVIDUAL rects rather than their bounding
/// box, so the client can mask the empty area BETWEEN them — the black flank beside a narrow popup,
/// which a bounding box cannot express. Front-to-back, target first. An empty answer means nothing
/// is on the display at all.
#[must_use]
pub fn content_rects(
    target_frame: VideoRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: &[WindowSnapshot],
    display_bounds: VideoRect,
    min_overlap_fraction: f64,
) -> Vec<VideoRect> {
    let mut rects = Vec::with_capacity(windows_in_front.len() + 1);
    let clamped_target = target_frame.intersection(&display_bounds);
    if !clamped_target.is_null() {
        rects.push(clamped_target);
    }
    let target_area = target_frame.width() * target_frame.height();
    #[expect(
        clippy::neg_cmp_op_on_partial_ord,
        reason = "mirrors union_region's NaN skip exactly — the two must agree case for case"
    )]
    if !(target_area > 0.0) {
        return rects;
    }
    for window in windows_in_front {
        if !is_attached_panel(
            window,
            target_frame,
            target_window_id,
            target_pid,
            target_area,
            min_overlap_fraction,
        ) {
            continue;
        }
        let clamped = window.frame.intersection(&display_bounds);
        if !clamped.is_null() {
            rects.push(clamped);
        }
    }
    rects
}

/// [`content_rects`]' answer projected into the capture's own PIXEL space — the transparency mask.
///
/// The union rect a dialog-expand capture is cropped to is a BOUNDING BOX, so a narrow popup beside
/// a wide window leaves a black flank the window server never drew into. The client masks that
/// flank out, and to do it it needs the opaque pieces in the decoder's texture space rather than in
/// the host's global points — which is this projection and nothing else.
///
/// Each global rect is expressed relative to `region`'s top-left, scaled by `capture_scale`, and
/// CLAMPED to the capture surface. A rect that clamps to nothing — a popup that closed between the
/// enumeration and this call, or one entirely outside the crop — is DROPPED rather than emitted as
/// a zero-sized rect: the client unions what it receives, and a degenerate member is one more rect
/// to carry for no pixels.
///
/// An EMPTY answer is meaningful and is what a contract sends: the plain window frame is fully
/// opaque, so an empty mask is the instruction to stop masking. The caller decides that; this only
/// projects.
///
/// The four edges are rounded INDEPENDENTLY, before the clamp and before the subtraction that makes
/// a width — the Swift's own order, which is what keeps two adjacent rects sharing an edge from
/// rounding into a one-pixel seam between them. Each `(edge - origin) * scale` stays a subtract
/// then a multiply, never a `mul_add`: `golden/golden_vectors.json` pins the sizes this feeds.
#[must_use]
pub fn mask_rects(
    content_rects_global: &[VideoRect],
    region: VideoRect,
    capture_scale: f64,
    pixel_width: i32,
    pixel_height: i32,
) -> Vec<MaskRect> {
    let max_width = f64::from(pixel_width);
    let max_height = f64::from(pixel_height);
    let mut out = Vec::with_capacity(content_rects_global.len());
    for rect in content_rects_global {
        let left = ((rect.min_x() - region.min_x()) * capture_scale).round();
        let top = ((rect.min_y() - region.min_y()) * capture_scale).round();
        let right = ((rect.max_x() - region.min_x()) * capture_scale).round();
        let bottom = ((rect.max_y() - region.min_y()) * capture_scale).round();
        // `Double.minimum`/`.maximum` rather than `<`/`>` ternaries, which is the crate's float
        // rule: a NaN edge — a garbage bounds read times a garbage scale — propagates through the
        // clamp instead of silently taking whichever branch a comparison against NaN happens to
        // take, and the `width > 0.0` guard below then drops the rect.
        let clamped_left = f64::min(f64::max(0.0, left), max_width);
        let clamped_top = f64::min(f64::max(0.0, top), max_height);
        let clamped_right = f64::min(f64::max(0.0, right), max_width);
        let clamped_bottom = f64::min(f64::max(0.0, bottom), max_height);
        let width = clamped_right - clamped_left;
        let height = clamped_bottom - clamped_top;
        #[expect(
            clippy::neg_cmp_op_on_partial_ord,
            reason = "a NaN edge must DROP the rect, which `<=` would not do — the same negated-positive \
                      spelling every skip test in this module uses"
        )]
        if !(width > 0.0) || !(height > 0.0) {
            continue;
        }
        out.push(MaskRect {
            x: wire_pixels(clamped_left),
            y: wire_pixels(clamped_top),
            width: wire_pixels(width),
            height: wire_pixels(height),
        });
    }
    out
}

/// One already-clamped, already-positive pixel edge as the wire carries it.
///
/// The saturation at [`u16::MAX`] is the wire's own limit rather than a second opinion about the
/// geometry: `pixel_width` may legitimately exceed 65535 on a large enough capture, and a mask that
/// wrapped there would name the left edge of the surface.
fn wire_pixels(pixels: f64) -> u16 {
    let bounded = f64::min(f64::max(0.0, pixels), f64::from(u16::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "clamped into u16's range on the line above, so no value is left that can wrap"
    )]
    let value = bounded as u16;
    value
}

/// Whether a region change is worth acting on: any edge differing by MORE than `min_delta` points.
///
/// Strict `>`, so a difference of exactly `min_delta` does NOT retarget — pinned case by case in
/// the golden corpus. Both rects are standardised first, matching `CGRect.minX`/`.width`, which is
/// what the Swift this replaced read.
#[must_use]
pub fn should_retarget(current: VideoRect, desired: VideoRect, min_delta: f64) -> bool {
    let (current, desired) = (current.standardized(), desired.standardized());
    (desired.min_x() - current.min_x()).abs() > min_delta
        || (desired.min_y() - current.min_y()).abs() > min_delta
        || (desired.size.width - current.size.width).abs() > min_delta
        || (desired.size.height - current.size.height).abs() > min_delta
}

/// Whether a window-move event should re-origin the input and cursor mapping to the PLAIN window
/// frame — only when no expanded region is active.
///
/// While DIALOG-EXPAND holds the region at window ∪ dialog, the mapping origin belongs to the union
/// and the stream is still union-sized. Re-origining would desync input from pixels: a normalised
/// client point in the dialog area, left of or above the window, would map to the wrong absolute
/// point, so clicks land wrong and the cursor reports not-visible over the dialog.
#[must_use]
pub const fn should_reorigin_to_window_on_geometry(active_region: Option<VideoRect>) -> bool {
    active_region.is_none()
}

/// What to do about a freshly measured union — the decision the geometry poll's handler makes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RegionDecision {
    /// Nothing moved past hysteresis. Leave the encoder alone.
    Hold,
    /// A dialog overhangs: retarget the capture to this region now.
    Expand(VideoRect),
    /// The dialog closed: go back to the plain window frame, debounced by the caller so that a
    /// menu re-opening inside the quiet window does not rebuild the encoder twice.
    Contract,
}

/// Decide what a new `union_global` means for a capture currently at `current_region` — `None`
/// being the plain window frame.
///
/// The "natural" region is the window frame; only a union STRICTLY larger than it — one that
/// contains the frame and differs from it — is an expansion. Everything else wants the frame back.
/// Both steps are hysteresis-gated by [`should_retarget`]: the first against the live region, so a
/// poll that lags a rebuild does not thrash it, and the second against the window frame, which is
/// what separates "expand to this" from "we are already home".
#[must_use]
pub fn region_decision(
    union_global: VideoRect,
    window_frame: VideoRect,
    current_region: Option<VideoRect>,
    min_delta: f64,
) -> RegionDecision {
    let desired = if union_global.contains_rect(&window_frame) && union_global != window_frame {
        union_global
    } else {
        window_frame
    };
    let current = current_region.unwrap_or(window_frame);
    if !should_retarget(current, desired, min_delta) {
        return RegionDecision::Hold;
    }
    if should_retarget(desired, window_frame, min_delta) {
        RegionDecision::Expand(desired)
    } else {
        RegionDecision::Contract
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_MIN_DELTA, DEFAULT_MIN_OVERLAP_FRACTION, RegionDecision, WindowSnapshot, content_rects,
        mask_rects, region_decision, should_reorigin_to_window_on_geometry, should_retarget, union_region,
    };
    use crate::geometry::VideoRect;
    use crate::video_control::MaskRect;

    const DISPLAY: VideoRect = VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0);
    const TARGET: VideoRect = VideoRect::xywh(120.0, 120.0, 700.0, 500.0);
    const TARGET_ID: u32 = 1783;
    const PID: i32 = 407;

    const fn snap(window_id: u32, owner_pid: i32, layer: i32, frame: VideoRect) -> WindowSnapshot {
        WindowSnapshot {
            window_id,
            owner_pid,
            layer,
            frame,
        }
    }

    fn union(windows: &[WindowSnapshot]) -> VideoRect {
        union_region(
            TARGET,
            TARGET_ID,
            PID,
            windows,
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        )
    }

    #[test]
    fn with_nothing_attached_the_region_is_the_clamped_window_frame() {
        assert_eq!(union(&[]), TARGET);
    }

    /// The HW-measured Chrome file dialog: same pid, layer 0, overhanging left and bottom.
    #[test]
    fn a_file_dialog_grows_the_region_to_cover_its_overhang() {
        let dialog = snap(1794, PID, 0, VideoRect::xywh(30.0, 203.0, 880.0, 448.0));
        assert_eq!(union(&[dialog]), VideoRect::xywh(30.0, 120.0, 880.0, 531.0));
    }

    #[test]
    fn a_window_that_is_not_this_apps_panel_never_joins_the_region() {
        // Another app's window, overlapping heavily — capturing it would leak its pixels.
        let other_app = snap(57, 388, 0, VideoRect::xywh(0.0, 0.0, 1400.0, 900.0));
        assert_eq!(union(&[other_app]), TARGET);
        // The target itself, which the window server may well list.
        assert_eq!(union(&[snap(TARGET_ID, PID, 0, TARGET)]), TARGET);
        // A tooltip: same pid, but layer 25 is system chrome.
        let tooltip = snap(99, PID, 25, VideoRect::xywh(100.0, 100.0, 900.0, 700.0));
        assert_eq!(union(&[tooltip]), TARGET);
        // A same-pid sibling overlapping by a sliver — incidental, below the fraction.
        let sliver = snap(900, PID, 0, VideoRect::xywh(815.0, 120.0, 600.0, 500.0));
        assert_eq!(union(&[sliver]), TARGET);
    }

    #[test]
    fn the_region_never_reaches_past_the_display() {
        let at_left_edge = VideoRect::xywh(0.0, 30.0, 700.0, 500.0);
        let dialog = snap(1794, PID, 0, VideoRect::xywh(-90.0, 100.0, 880.0, 448.0));
        let region = union_region(
            at_left_edge,
            TARGET_ID,
            PID,
            &[dialog],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(
            region,
            VideoRect::xywh(0.0, 30.0, 790.0, 518.0),
            "the union reaches to x = -90, and the clamp cuts exactly that off"
        );
        assert!(region.max_x() <= DISPLAY.max_x());
    }

    #[test]
    fn the_content_rects_are_the_pieces_the_bounding_box_cannot_express() {
        let popup = snap(1794, PID, 101, VideoRect::xywh(700.0, 300.0, 200.0, 600.0));
        let rects = content_rects(
            TARGET,
            TARGET_ID,
            PID,
            &[popup, snap(57, 388, 0, DISPLAY)],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(
            rects,
            vec![TARGET, VideoRect::xywh(700.0, 300.0, 200.0, 600.0)],
            "the target first, then the panel; the other app's window is not a piece"
        );
    }

    #[test]
    fn a_target_off_the_display_entirely_contributes_no_content_rect() {
        let elsewhere = VideoRect::xywh(4000.0, 4000.0, 100.0, 100.0);
        assert!(
            content_rects(
                elsewhere,
                TARGET_ID,
                PID,
                &[],
                DISPLAY,
                DEFAULT_MIN_OVERLAP_FRACTION
            )
            .is_empty()
        );
    }

    #[test]
    fn hysteresis_holds_a_drift_and_passes_a_real_expansion() {
        let grown = VideoRect::xywh(117.0, 117.0, 706.0, 506.0);
        assert!(!should_retarget(TARGET, grown, DEFAULT_MIN_DELTA));
        assert!(should_retarget(
            TARGET,
            VideoRect::xywh(30.0, 120.0, 880.0, 531.0),
            DEFAULT_MIN_DELTA
        ));
        assert!(
            !should_retarget(
                TARGET,
                VideoRect::xywh(128.0, 120.0, 700.0, 500.0),
                DEFAULT_MIN_DELTA
            ),
            "exactly the threshold is not past it"
        );
    }

    #[test]
    fn the_mapping_re_origins_only_while_the_capture_is_at_the_plain_window_frame() {
        assert!(should_reorigin_to_window_on_geometry(None));
        assert!(!should_reorigin_to_window_on_geometry(Some(VideoRect::xywh(
            20.0, 70.0, 880.0, 560.0
        ))));
    }

    #[test]
    fn a_union_larger_than_the_window_expands_and_its_disappearance_contracts() {
        let expanded = VideoRect::xywh(30.0, 120.0, 880.0, 531.0);
        assert_eq!(
            region_decision(expanded, TARGET, None, DEFAULT_MIN_DELTA),
            RegionDecision::Expand(expanded),
            "the union contains the frame and differs from it"
        );
        assert_eq!(
            region_decision(TARGET, TARGET, Some(expanded), DEFAULT_MIN_DELTA),
            RegionDecision::Contract,
            "the dialog closed, so the plain frame is wanted back"
        );
        assert_eq!(
            region_decision(TARGET, TARGET, None, DEFAULT_MIN_DELTA),
            RegionDecision::Hold,
            "already home"
        );
        assert_eq!(
            region_decision(expanded, TARGET, Some(expanded), DEFAULT_MIN_DELTA),
            RegionDecision::Hold,
            "already expanded to exactly this"
        );
    }

    #[test]
    fn a_union_that_merely_moved_off_the_window_is_not_an_expansion() {
        // A union not CONTAINING the window frame cannot be a dialog attached to it, whatever its
        // size — so the decision is about going home, not about growing.
        let adrift = VideoRect::xywh(900.0, 900.0, 900.0, 900.0);
        assert_eq!(
            region_decision(adrift, TARGET, Some(adrift), DEFAULT_MIN_DELTA),
            RegionDecision::Contract
        );
    }

    /// The projection is relative to the REGION's origin and scaled, which is the whole conversion:
    /// a window at the union's top-left starts at pixel zero however far from the desktop origin
    /// the union sits, and a 2× capture doubles every edge.
    #[test]
    fn the_mask_is_relative_to_the_region_and_scaled_into_capture_pixels() {
        let region = VideoRect::xywh(100.0, 100.0, 1000.0, 600.0);
        let contents = [
            VideoRect::xywh(100.0, 100.0, 700.0, 500.0),
            VideoRect::xywh(700.0, 300.0, 400.0, 400.0),
        ];
        assert_eq!(mask_rects(&contents, region, 2.0, 2000, 1200), vec![
            MaskRect {
                x: 0,
                y: 0,
                width: 1400,
                height: 1000,
            },
            MaskRect {
                x: 1200,
                y: 400,
                width: 800,
                height: 800,
            },
        ]);
    }

    /// A rect reaching past the capture surface is CLAMPED to it rather than dropped — the overhang
    /// is real content, and the client masks the part it can actually see.
    #[test]
    fn a_rect_overhanging_the_surface_is_clamped_rather_than_lost() {
        let region = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);
        let contents = [VideoRect::xywh(600.0, 400.0, 800.0, 800.0)];
        assert_eq!(mask_rects(&contents, region, 1.0, 800, 600), vec![MaskRect {
            x: 600,
            y: 400,
            width: 200,
            height: 200,
        }]);
    }

    /// A rect entirely outside the crop, and a NaN one, both DROP. Neither has pixels the client
    /// could mask, and a zero-sized member is one more rect to carry for nothing.
    #[test]
    fn a_rect_with_no_pixels_inside_the_crop_is_dropped_entirely() {
        let region = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);
        let contents = [
            VideoRect::xywh(2000.0, 2000.0, 100.0, 100.0),
            VideoRect::xywh(f64::NAN, 0.0, 100.0, 100.0),
            VideoRect::xywh(10.0, 10.0, 0.0, 50.0),
        ];
        assert!(mask_rects(&contents, region, 1.0, 800, 600).is_empty());
    }

    /// Nothing in, nothing out — which is exactly the datagram a CONTRACT sends to clear the mask.
    #[test]
    fn an_empty_content_list_projects_to_an_empty_mask() {
        assert!(mask_rects(&[], VideoRect::xywh(0.0, 0.0, 800.0, 600.0), 2.0, 1600, 1200).is_empty());
    }

    /// A capture surface wider than the wire's own 16-bit field saturates rather than wrapping. A
    /// wrap here would name the LEFT edge of the surface and mask the wrong pixels entirely.
    #[test]
    fn an_edge_past_the_wires_range_saturates_rather_than_wrapping() {
        let region = VideoRect::xywh(0.0, 0.0, 80_000.0, 600.0);
        let contents = [VideoRect::xywh(70_000.0, 0.0, 9_000.0, 600.0)];
        assert_eq!(mask_rects(&contents, region, 1.0, 80_000, 600), vec![MaskRect {
            x: u16::MAX,
            y: 0,
            width: 9_000,
            height: 600,
        }]);
    }
}
