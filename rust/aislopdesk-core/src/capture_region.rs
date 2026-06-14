//! Pure capture-region geometry for the host DIALOG-EXPAND feature.
//!
//! The canonical capture-region logic; the macOS host shell calls it over the C ABI
//! (`RustVideoHostFFI.capture*`) from `WindowGeometryWatcher` and the host session.
//!
//! Decides the capture region = target window frame ∪ any associated panel windows (a
//! file-open / print / share dialog the OS attaches to the window), clamped to the
//! display, so a dialog larger than the streamed window shows in full and is clickable —
//! instead of being cropped to the window frame by the display-anchored crop.
//!
//! The association is by **owning process**: the open/save panel is attributed to the
//! host app's own pid (HW-verified 2026-06-12: a Chrome file dialog enumerates as
//! `pid==Chrome, layer==0, name=="Open"`). So a panel qualifies when it is a DIFFERENT
//! window owned by the SAME pid, on the normal window layer (`0`), overlapping the target
//! by ≥ `min_overlap_fraction` of the smaller rect's area. Plus a hysteresis gate for
//! committing a region change ([`should_retarget`]) and the re-origin decision while a
//! union region is active ([`should_reorigin_to_window_on_geometry`]).
//!
//! STATELESS: all three functions are pure; the module holds no map/ledger/refcount, so
//! there is no `HashMap`/`BTreeMap` here. `windows_in_front` is a slice iterated in order
//! (front-to-back, the slice strictly IN FRONT of the target), matching Swift `for w in`
//! over the `[WindowSnapshot]` array — deterministic, no iteration-order concern. All
//! `CGRect` operations (standardized `width`/`height`, `intersection`, `union`, the
//! `CGRectNull` outcome) are delegated to the CG-faithful helpers on
//! [`crate::geometry::VideoRect`]; this module does not reinvent them.

use crate::geometry::VideoRect;

/// Minimum overlap fraction (of the smaller rect's area) for a same-pid front window to
/// count as an attached panel. The Swift shell uses this as the default argument (`0.30`).
pub const DEFAULT_MIN_OVERLAP_FRACTION: f64 = 0.30;

/// Per-edge hysteresis threshold (points) for [`should_retarget`]. The Swift shell uses
/// this as the default argument (`8`).
pub const DEFAULT_MIN_DELTA: f64 = 8.0;

/// One on-screen window, as read from `CGWindowListCopyWindowInfo` (CG top-left points).
/// The host shell marshals each `CGWindowList` row into this over the C ABI.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WindowSnapshot {
    /// `kCGWindowNumber` (Swift `UInt32`).
    pub window_id: u32,
    /// `kCGWindowOwnerPID` (Swift `Int32`).
    pub owner_pid: i32,
    /// `kCGWindowLayer`; `0` == the normal window layer (Swift `Int` → `i64`).
    pub layer: i64,
    /// `kCGWindowBounds`, CG top-left space.
    pub frame: VideoRect,
}

impl WindowSnapshot {
    /// Builds a window snapshot.
    #[must_use]
    pub const fn new(window_id: u32, owner_pid: i32, layer: i64, frame: VideoRect) -> Self {
        Self {
            window_id,
            owner_pid,
            layer,
            frame,
        }
    }
}

/// The union of `target_frame` with every qualifying associated panel in `windows_in_front`,
/// clamped to `display_bounds`.
///
/// `windows_in_front` is in front-to-back order, the slice strictly IN FRONT of the target.
/// Returns `target_frame` (clamped) when nothing qualifies — i.e. no
/// dialog, or the dialog fits inside the window.
///
/// A window qualifies as an attached panel when it is: a DIFFERENT window than the target,
/// owned by `target_pid`, on the normal window layer (`0` — excludes the menu bar / Dock /
/// backstop / tooltips at other levels), and overlapping the target by a meaningful
/// fraction (≥ `min_overlap_fraction` of the SMALLER rect's area — skips an incidental 1px
/// edge touch from a sibling window). The whole panel frame joins the union even where it
/// overhangs the window.
///
/// The return is a concrete `VideoRect`; the CoreGraphics "null rectangle" outcome
/// (zero-area target, or target/union fully off the display) is represented as
/// [`VideoRect::NULL`] (`∞, ∞, 0, 0`), exactly as Swift returns `CGRectNull`. Pass
/// [`DEFAULT_MIN_OVERLAP_FRACTION`] for the Swift default.
#[must_use]
pub fn union_region(
    target_frame: VideoRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: &[WindowSnapshot],
    display_bounds: VideoRect,
    min_overlap_fraction: f64,
) -> VideoRect {
    let mut union = target_frame;
    // CGRect.width / .height are standardized (always ≥ 0).
    let target_area = target_frame.width() * target_frame.height();
    // `guard targetArea > 0 else { return targetFrame.intersection(displayBounds) }`.
    // `!(x > 0.0)` (not `x <= 0.0`) gives NaN-skips-guard semantics (the Swift shell matches this).
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    if !(target_area > 0.0) {
        return target_frame
            .intersection(&display_bounds)
            .unwrap_or(VideoRect::NULL);
    }
    for w in windows_in_front {
        // `guard w.windowID != targetWindowID, w.ownerPID == targetPID, w.layer == 0 else { continue }`.
        if w.window_id == target_window_id || w.owner_pid != target_pid || w.layer != 0 {
            continue;
        }
        // `let inter = w.frame.intersection(targetFrame); guard !inter.isNull else { continue }`
        // — CGRectIsNull is disjoint OR edge-touch (zero-area overlap).
        let Some(inter) = w.frame.intersection(&target_frame) else {
            continue;
        };
        let inter_area = inter.width() * inter.height();
        let w_area = w.frame.width() * w.frame.height();
        // Swift global `min(targetArea, wArea)` == `wArea < targetArea ? wArea : targetArea`
        // (differs from f64::min on NaN; inputs are finite here, kept explicit for fidelity).
        let smaller_area = if w_area < target_area {
            w_area
        } else {
            target_area
        };
        // `guard smallerArea > 0, interArea / smallerArea >= minOverlapFraction else { continue }`.
        // `>=` is inclusive (overlap exactly == fraction qualifies); negated guards stay `!(…)`.
        #[allow(clippy::neg_cmp_op_on_partial_ord)]
        if !(smaller_area > 0.0) || !(inter_area / smaller_area >= min_overlap_fraction) {
            continue;
        }
        union = union.union(&w.frame);
    }
    // `let clamped = union.intersection(displayBounds)`
    // `return clamped.isNull ? targetFrame.intersection(displayBounds) : clamped`.
    union.intersection(&display_bounds).unwrap_or_else(|| {
        target_frame
            .intersection(&display_bounds)
            .unwrap_or(VideoRect::NULL)
    })
}

/// Hysteresis gate for committing a region change.
///
/// Each change is an encoder rebuild + IDR,
/// so only retarget when the `desired` region differs from the `current` capture region by
/// more than `min_delta` points on ANY edge. Returns `true` when the change is worth a
/// rebuild. Pass [`DEFAULT_MIN_DELTA`] for the Swift default.
///
/// Uses `abs()` and a strict `>`; a single edge differing by exactly `min_delta` does NOT
/// retarget. The capture regions fed here are always positive-size, so the raw
/// [`min_x`](VideoRect::min_x)/[`min_y`](VideoRect::min_y) equal CG `.minX`/`.minY`; only
/// the standardized [`width`](VideoRect::width)/[`height`](VideoRect::height) accessors are
/// needed for the size deltas.
#[must_use]
pub fn should_retarget(current: VideoRect, desired: VideoRect, min_delta: f64) -> bool {
    (desired.min_x() - current.min_x()).abs() > min_delta
        || (desired.min_y() - current.min_y()).abs() > min_delta
        || (desired.width() - current.width()).abs() > min_delta
        || (desired.height() - current.height()).abs() > min_delta
}

/// Whether a window-move geometry event should re-origin the input/cursor mapping to the
/// PLAIN window frame.
///
/// NO while a DIALOG-EXPAND capture region is active
/// (`active_region_global` is `Some`): the mapping origin is then owned by the union region
/// (set in `applyCaptureRegion` against window ∪ dialog), and the stream is still
/// union-sized. Re-origining to the plain window frame would desync input/cursor from that
/// stream — a normalized client point in the dialog area (left/above the window) would map
/// to a wrong absolute point (clicks land wrong) and the cursor would report not-visible
/// over the dialog. The Swift shell's `activeRegionGlobal == nil` mirrors this.
#[must_use]
pub const fn should_reorigin_to_window_on_geometry(
    active_region_global: Option<VideoRect>,
) -> bool {
    active_region_global.is_none()
}

#[cfg(test)]
mod tests {
    use super::*; // re-exports `VideoRect` via the module-level `use crate::geometry::VideoRect`.

    const DISPLAY: VideoRect = VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0);
    const TARGET: VideoRect = VideoRect::xywh(120.0, 120.0, 700.0, 500.0);
    const TARGET_WID: u32 = 1783;
    const PID: i32 = 407;

    fn r(x: f64, y: f64, w: f64, h: f64) -> VideoRect {
        VideoRect::xywh(x, y, w, h)
    }

    // ----- capture-region cases (the host `CaptureRegionMathTests` suite drives these via the FFI) -----

    /// `testNoDialogReturnsWindowFrame`: no associated windows → just the (clamped) frame.
    #[test]
    fn no_dialog_returns_window_frame() {
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// `testFileDialogExpandsUnion`: the HW-measured Chrome file dialog grows the union.
    #[test]
    fn file_dialog_expands_union() {
        let dialog = WindowSnapshot::new(1794, PID, 0, r(30.0, 203.0, 880.0, 448.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[dialog],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        // union of (120,120,700,500) ∪ (30,203,880,448) = x[30,910] y[120,651].
        assert_eq!(out, r(30.0, 120.0, 880.0, 531.0));
    }

    /// `testOtherAppWindowIgnored`: a different app's overlapping window does not bleed in.
    #[test]
    fn other_app_window_ignored() {
        let slack = WindowSnapshot::new(57, 388, 0, r(0.0, 0.0, 1400.0, 900.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[slack],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// `testTargetWindowItselfIgnored`: the target appearing in the list does not self-union.
    #[test]
    fn target_window_itself_ignored() {
        let self_snap = WindowSnapshot::new(TARGET_WID, PID, 0, TARGET);
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[self_snap],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// `testNonZeroLayerIgnored`: non-zero layers (menu bar, Dock, tooltips) are excluded.
    #[test]
    fn non_zero_layer_ignored() {
        let tooltip = WindowSnapshot::new(99, PID, 25, r(100.0, 100.0, 900.0, 700.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[tooltip],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// `testSliverOverlapIgnored`: an incidental sliver below the fraction is ignored.
    #[test]
    fn sliver_overlap_ignored() {
        let sibling = WindowSnapshot::new(900, PID, 0, r(815.0, 120.0, 600.0, 500.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[sibling],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        // inter (815,120,5,500) area 2500 / smaller 300000 = 0.0083 < 0.30 → skipped.
        assert_eq!(out, TARGET);
    }

    /// `testUnionClampedToDisplay`: a dialog overhanging the left edge can't grab off-display.
    #[test]
    fn union_clamped_to_display() {
        let left_edge_target = r(0.0, 30.0, 700.0, 500.0);
        let dialog = WindowSnapshot::new(1794, PID, 0, r(-90.0, 100.0, 880.0, 448.0));
        let out = union_region(
            left_edge_target,
            TARGET_WID,
            PID,
            &[dialog],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        // clamped, no negative origin; max_x ≤ display max_x.
        assert_eq!(out.min_x(), 0.0);
        assert!(out.std_max_x() <= DISPLAY.std_max_x());
        // exact: (-90,30,880,518) ∩ display → (0,30,790,518).
        assert_eq!(out, r(0.0, 30.0, 790.0, 518.0));
    }

    /// `testShouldRetargetHysteresis`: sub-threshold drift no-ops; a real expansion retargets.
    #[test]
    fn should_retarget_hysteresis() {
        let a = r(120.0, 120.0, 700.0, 500.0);
        // a.insetBy(dx: -3, dy: -3) == (117,117,706,506); every edge Δ ≤ 8 → false.
        let inset = r(117.0, 117.0, 706.0, 506.0);
        assert!(!should_retarget(a, inset, DEFAULT_MIN_DELTA));
        assert!(should_retarget(
            a,
            r(30.0, 120.0, 880.0, 531.0),
            DEFAULT_MIN_DELTA
        ));
    }

    /// `testGeometryReoriginSkippedWhileCaptureRegionExpanded`.
    #[test]
    fn geometry_reorigin_skipped_while_capture_region_expanded() {
        assert!(should_reorigin_to_window_on_geometry(None));
        let union = r(20.0, 70.0, 880.0, 560.0);
        assert!(!should_reorigin_to_window_on_geometry(Some(union)));
    }

    // ----- additional branch / edge unit tests (spec edge_cases) -----

    /// Zero-area target (width 0): `targetArea > 0` fails → returns `target ∩ display`. Per
    /// CoreGraphics, that intersection is a NON-null zero-WIDTH rect `(120,120,0,500)` (the
    /// zero-width target lies inside the display's x-range, so `x2 == x1`, not `x2 < x1`),
    /// NOT `CGRectNull`. Golden-parity proves this matches real Swift `CGRectIntersection`.
    #[test]
    fn zero_area_target_returns_clamped_zero_width_rect() {
        let out = union_region(
            r(120.0, 120.0, 0.0, 500.0),
            TARGET_WID,
            PID,
            &[],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert!(!out.is_null());
        assert_eq!(out, r(120.0, 120.0, 0.0, 500.0));
    }

    /// Target fully off the display (positive area) → union ∩ display null, fallback null too.
    #[test]
    fn off_display_target_returns_null() {
        let out = union_region(
            r(5000.0, 5000.0, 100.0, 100.0),
            TARGET_WID,
            PID,
            &[],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert!(out.is_null());
        assert_eq!(out, VideoRect::NULL);
    }

    /// Zero-area display bounds → every clamp intersection is null → null.
    #[test]
    fn zero_area_display_returns_null() {
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[],
            r(0.0, 0.0, 0.0, 0.0),
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert!(out.is_null());
        assert_eq!(out, VideoRect::NULL);
    }

    /// Disjoint same-pid layer-0 window → intersection None → skipped, union unchanged.
    #[test]
    fn disjoint_same_pid_window_ignored() {
        let disjoint = WindowSnapshot::new(200, PID, 0, r(1500.0, 800.0, 300.0, 200.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[disjoint],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// Edge-touch same-pid window (x-overlap width 0) → intersection None → skipped.
    #[test]
    fn edge_touch_same_pid_window_ignored() {
        // target x-range [120,820]; this window starts exactly at x=820.
        let touching = WindowSnapshot::new(201, PID, 0, r(820.0, 120.0, 200.0, 500.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[touching],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, TARGET);
    }

    /// Overlap exactly == `min_overlap_fraction` → INCLUDED (`>=` is inclusive).
    #[test]
    fn boundary_fraction_inclusive() {
        let target = r(0.0, 0.0, 100.0, 100.0);
        let win = WindowSnapshot::new(300, PID, 0, r(50.0, 0.0, 100.0, 100.0));
        // inter (50,0,50,100) area 5000 / smaller 10000 = 0.5 == 0.5 → joins.
        let out = union_region(target, TARGET_WID, PID, &[win], DISPLAY, 0.5);
        assert_eq!(out, r(0.0, 0.0, 150.0, 100.0));
    }

    /// Overlap just below the fraction → EXCLUDED.
    #[test]
    fn just_below_boundary_excluded() {
        let target = r(0.0, 0.0, 100.0, 100.0);
        let win = WindowSnapshot::new(300, PID, 0, r(50.0, 0.0, 100.0, 100.0));
        // 0.5 ratio < 0.6 threshold → skipped.
        let out = union_region(target, TARGET_WID, PID, &[win], DISPLAY, 0.6);
        assert_eq!(out, target);
    }

    /// Negative-size window frame standardizes → qualifies identically to its positive form.
    #[test]
    fn negative_size_window_standardizes() {
        // (910,651,-880,-448) standardizes to (30,203,880,448) == the case-B dialog.
        let dialog = WindowSnapshot::new(1794, PID, 0, r(910.0, 651.0, -880.0, -448.0));
        let out = union_region(
            TARGET,
            TARGET_WID,
            PID,
            &[dialog],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, r(30.0, 120.0, 880.0, 531.0));
    }

    /// Negative-size target frame standardizes → loop runs (area uses abs), clamp standardizes.
    #[test]
    fn negative_size_target_standardizes() {
        // (820,620,-700,-500) standardizes to (120,120,700,500).
        let out = union_region(
            r(820.0, 620.0, -700.0, -500.0),
            TARGET_WID,
            PID,
            &[],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out, r(120.0, 120.0, 700.0, 500.0));
    }

    /// Multiple qualifying dialogs accumulate into one bounding union; order-independent.
    #[test]
    fn multiple_dialogs_accumulate() {
        let target = r(200.0, 200.0, 400.0, 300.0); // x[200,600] y[200,500]
                                                    // A (100,250,200,200): inter (200,250,100,200)=20000 / smaller 40000 = 0.5 → joins.
        let a = WindowSnapshot::new(1, PID, 0, r(100.0, 250.0, 200.0, 200.0));
        // B (400,150,300,400): inter (400,200,200,300)=60000 / smaller 120000 = 0.5 → joins.
        let b = WindowSnapshot::new(2, PID, 0, r(400.0, 150.0, 300.0, 400.0));
        // union: target ∪ A ∪ B = x[100,700] y[150,550] → (100,150,600,400).
        let expected = r(100.0, 150.0, 600.0, 400.0);
        let out_ab = union_region(
            target,
            TARGET_WID,
            PID,
            &[a, b],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        let out_ba = union_region(
            target,
            TARGET_WID,
            PID,
            &[b, a],
            DISPLAY,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        assert_eq!(out_ab, expected);
        assert_eq!(out_ba, expected); // min/max are exact → order-independent.
    }

    // ----- should_retarget edge tests -----

    /// Identical rects → false.
    #[test]
    fn should_retarget_identical_is_false() {
        let a = r(120.0, 120.0, 700.0, 500.0);
        assert!(!should_retarget(a, a, DEFAULT_MIN_DELTA));
    }

    /// A single edge differing by exactly `min_delta` → false (strict `>`).
    #[test]
    fn should_retarget_exact_threshold_is_false() {
        let cur = r(120.0, 120.0, 700.0, 500.0);
        // Δx == 8 exactly.
        let des = r(128.0, 120.0, 700.0, 500.0);
        assert!(!should_retarget(cur, des, DEFAULT_MIN_DELTA));
    }

    /// Any single edge over `min_delta` → true (one assertion per edge).
    #[test]
    fn should_retarget_any_edge_over_is_true() {
        let cur = r(120.0, 120.0, 700.0, 500.0);
        assert!(should_retarget(
            cur,
            r(128.5, 120.0, 700.0, 500.0),
            DEFAULT_MIN_DELTA
        )); // minX
        assert!(should_retarget(
            cur,
            r(120.0, 128.5, 700.0, 500.0),
            DEFAULT_MIN_DELTA
        )); // minY
        assert!(should_retarget(
            cur,
            r(120.0, 120.0, 708.5, 500.0),
            DEFAULT_MIN_DELTA
        )); // width
        assert!(should_retarget(
            cur,
            r(120.0, 120.0, 700.0, 508.5),
            DEFAULT_MIN_DELTA
        )); // height
    }

    /// Custom `min_delta == 0`: identical → false, any nonzero diff → true.
    #[test]
    fn should_retarget_custom_zero_delta() {
        let cur = r(120.0, 120.0, 700.0, 500.0);
        assert!(!should_retarget(cur, cur, 0.0));
        assert!(should_retarget(cur, r(120.0, 120.0, 700.5, 500.0), 0.0));
    }

    // ----- should_reorigin -----

    /// None → true; Some → false.
    #[test]
    fn should_reorigin_none_true_some_false() {
        assert!(should_reorigin_to_window_on_geometry(None));
        assert!(!should_reorigin_to_window_on_geometry(Some(r(
            20.0, 70.0, 880.0, 560.0
        ))));
    }

    /// Default constants match the Swift shell's default arguments.
    #[test]
    fn default_constants_match_swift() {
        assert_eq!(DEFAULT_MIN_OVERLAP_FRACTION, 0.30);
        assert_eq!(DEFAULT_MIN_DELTA, 8.0);
    }
}
