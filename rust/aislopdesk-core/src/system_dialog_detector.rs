//! Pure classifier behind the "show system popups/prompts in their own pane" feature.
//!
//! The canonical `SystemDialogDetector` logic; the native Swift shell keeps a copy
//! (`Sources/AislopdeskVideoHost/SystemDialogDetector.swift`) that tracks this (golden parity).
//!
//! A SYSTEM dialog is a cross-process modal window that NO app-pane would ever capture — the
//! prime case (the user's ask) being a `SecurityAgent` login/admin **password** prompt. The host
//! enumerates the on-screen windows, runs this classifier, and answers the client's
//! `listSystemDialogs` poll with the matches; the client auto-spawns an ephemeral pane per dialog.
//!
//! **HW-grounded (probe 2026-06-12, Tahoe 26.5.1):** `SCShareableContent` DOES list the
//! `SecurityAgent` prompt (own window, layer 1000, onScreen) and it captures with real pixels — it
//! is NOT capture-blocked. But while it is up `IsSecureEventInputEnabled() == true`, so synthetic
//! KEYSTROKES are OS-dropped: a secure dialog is **view + click only**, the password must be typed
//! on the host. That truth is carried per-dialog as [`Dialog::is_secure`] so the client can label it.
//!
//! **Scope (v1):** system AUTH prompts only — `SecurityAgent` / `coreauthd`. The allowlists below
//! are the single expansion point — adding a new system-prompt source is one entry.
//!
//! Swift gates the source with `#if os(macOS)` (it imports CoreGraphics + is host-only). This core
//! is PLATFORM-INDEPENDENT pure logic (string membership + geometry), so it is NOT cfg-gated.
//!
//! Stateless: no map/ledger, no refcounting. Membership lookups only + an order-preserving filter,
//! so there are ZERO `HashMap`/`BTreeMap` iteration-order concerns.

use crate::geometry::VideoRect;

/// One enumerated on-screen window (the fields [`classify`] reads).
///
/// Built from an `SCWindow` on
/// the host; kept as a plain value so the classifier is pure + testable off-device.
/// The Swift shell's `WindowSnapshot` mirrors this (Equatable, Sendable). `PartialEq` only —
/// `frame` holds `f64` (no `Eq`), matching `CGRect`'s float `==` (NaN != NaN).
#[derive(Debug, Clone, PartialEq)]
pub struct WindowSnapshot {
    /// The CoreGraphics window id (`SCWindow.windowID`).
    pub window_id: u32,
    /// The owning process's name (e.g. `"SecurityAgent"`). The resilient signal across macOS builds.
    pub owner_name: String,
    /// The owning app's bundle id (e.g. `"com.apple.SecurityAgent"`); may be empty.
    pub bundle_id: String,
    /// Whether the window is currently on screen (`SCWindow.isOnScreen`).
    pub is_on_screen: bool,
    /// The window title; may be empty.
    pub title: String,
    /// The window frame in host display space.
    pub frame: VideoRect,
}

impl WindowSnapshot {
    /// Builds a snapshot from its enumerated fields.
    #[must_use]
    pub const fn new(
        window_id: u32,
        owner_name: String,
        bundle_id: String,
        is_on_screen: bool,
        title: String,
        frame: VideoRect,
    ) -> Self {
        Self {
            window_id,
            owner_name,
            bundle_id,
            is_on_screen,
            title,
            frame,
        }
    }
}

/// A classified system dialog (shape mirrors the wire `SystemDialogSummary`). The Swift
/// shell's `Dialog` mirrors this (Equatable, Sendable). All-exact fields → derive `Eq`.
///
/// NOTE: Swift `Dialog.width`/`height` are `Int` (= `Int64` on the 64-bit host) → `i64` here.
/// (The wire `SystemDialogSummary` later narrows to `u16`; that narrowing is NOT this module.)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dialog {
    /// The CoreGraphics window id to surface.
    pub window_id: u32,
    /// The display label — owner name, or the bundle id when the owner name is empty.
    pub owner: String,
    /// The window title (passed through unchanged).
    pub title: String,
    /// The rounded, standardized (non-negative) width in points.
    pub width: i64,
    /// The rounded, standardized (non-negative) height in points.
    pub height: i64,
    /// `true` ⇒ Secure Event Input class (password/auth) — view + click only, keystrokes dropped.
    pub is_secure: bool,
}

/// Secure auth processes — raise Secure Event Input (view + click, no typing). Matched by bundle
/// id OR owner name. Membership-only; order irrelevant. The Swift shell's `secureBundleIDs` mirrors this.
const SECURE_BUNDLE_IDS: &[&str] = &["com.apple.SecurityAgent", "com.apple.coreauthd"];
/// Secure auth owner names (the name is the resilient signal across macOS builds; `SCWindow` gives
/// both). The Swift shell's `secureOwnerNames` mirrors this.
const SECURE_OWNER_NAMES: &[&str] = &["SecurityAgent", "coreauthd"];
/// Non-secure system-prompt bundle ids (view + FULL interaction). EMPTY in v1 — the expansion
/// point. The Swift shell's `systemBundleIDs` mirrors this.
const SYSTEM_BUNDLE_IDS: &[&str] = &[];
/// Non-secure system-prompt owner names. EMPTY in v1 — the expansion point. The Swift shell's
/// `systemOwnerNames` mirrors this.
const SYSTEM_OWNER_NAMES: &[&str] = &[];

/// Reject sub-`MIN_SIZE` windows (offscreen helpers, 1×1 indicators) — a real prompt is well above
/// this. The Swift shell's `minSize` default is `60`.
pub const MIN_SIZE: i64 = 60;

/// Classify one window, or `None` if it is not a surfaced system dialog. Pure. The canonical
/// `classify(_:minSize:)` implementation.
///
/// Rust has no default args → the caller passes `min_size`; use [`classify_default`] for the Swift
/// `minSize: minSize` default.
///
/// CoreGraphics `CGRect.width`/`.height` are STANDARDIZED (always non-negative), so this uses
/// [`VideoRect::width`]/[`VideoRect::height`] (abs-based). Swift `Double.rounded()` (half away from
/// zero) == Rust `f64::round()`, and Swift `Int(_)` == `as i64` for the finite, in-range, already
/// integral values produced by `.round()` (production frames never hit the NaN/overflow edge where
/// Swift traps and Rust saturates).
#[must_use]
pub fn classify(w: &WindowSnapshot, min_size: i64) -> Option<Dialog> {
    let width = w.frame.width().round() as i64;
    let height = w.frame.height().round() as i64;
    if !(w.is_on_screen && width >= min_size && height >= min_size) {
        return None;
    }
    let is_secure = SECURE_BUNDLE_IDS.contains(&w.bundle_id.as_str())
        || SECURE_OWNER_NAMES.contains(&w.owner_name.as_str());
    // `is_system && !is_secure` is UNREACHABLE in v1 (the system allowlists are empty); kept
    // in full so growing the allowlists is a one-line change.
    let is_system = is_secure
        || SYSTEM_BUNDLE_IDS.contains(&w.bundle_id.as_str())
        || SYSTEM_OWNER_NAMES.contains(&w.owner_name.as_str());
    if !is_system {
        return None;
    }
    let label = if w.owner_name.is_empty() {
        w.bundle_id.clone()
    } else {
        w.owner_name.clone()
    };
    Some(Dialog {
        window_id: w.window_id,
        owner: label,
        title: w.title.clone(),
        width,
        height,
        is_secure,
    })
}

/// [`classify`] with the default [`MIN_SIZE`] (the Swift shell uses `minSize: minSize` as the default arg).
#[must_use]
pub fn classify_default(w: &WindowSnapshot) -> Option<Dialog> {
    classify(w, MIN_SIZE)
}

/// Classify a whole snapshot list into the system dialogs to surface (input ORDER PRESERVED). The
/// canonical `detect(_:minSize:)` implementation (Swift `compactMap`; the Swift shell mirrors this).
#[must_use]
pub fn detect(windows: &[WindowSnapshot], min_size: i64) -> Vec<Dialog> {
    windows
        .iter()
        .filter_map(|w| classify(w, min_size))
        .collect()
}

/// [`detect`] with the default [`MIN_SIZE`].
#[must_use]
pub fn detect_default(windows: &[WindowSnapshot]) -> Vec<Dialog> {
    detect(windows, MIN_SIZE)
}

/// Whether synthetic client keystrokes will be DROPPED for a surfaced dialog RIGHT NOW.
///
/// The live truth behind the client's "type the password on the host" hint, distinct from the static
/// [`Dialog::is_secure`] classification. `is_secure` is the dialog CLASS (a `SecurityAgent`/`coreauthd`
/// password field); it is `true` even for a `do shell script with administrator privileges` prompt
/// that still accepts synthetic typing. `secure_input_active` is the host's LIVE
/// `IsSecureEventInputEnabled()` reading — `true` only while the OS is routing the keyboard directly to
/// a secure field, the one case `CGEvent` keystrokes are dropped. `virtual_keyboard_available` is
/// whether a `DriverKit` virtual-HID keyboard can bypass Secure Event Input (the host `InputInjector`
/// can type into a secure field through it).
///
/// Keystrokes are blocked iff the dialog is a secure-class prompt AND Secure Event Input is actually
/// active AND no virtual-HID keyboard can reach around it. A secure-CLASS dialog whose Secure Event
/// Input is NOT active (`secure_input_active == false`) is typable from the client → not blocked.
/// Pure.
#[must_use]
pub const fn keystrokes_blocked(
    is_secure: bool,
    secure_input_active: bool,
    virtual_keyboard_available: bool,
) -> bool {
    is_secure && secure_input_active && !virtual_keyboard_available
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test helper (matches the Swift `SystemDialogDetectorTests.swift` `snap(...)` convention).
    /// Frame origin (830, 201) like the HW probe; the classifier reads only the standardized
    /// extent, so the origin is irrelevant.
    fn snap(
        id: u32,
        owner: &str,
        bundle: &str,
        on_screen: bool,
        w: f64,
        h: f64,
        title: &str,
    ) -> WindowSnapshot {
        WindowSnapshot::new(
            id,
            owner.to_string(),
            bundle.to_string(),
            on_screen,
            title.to_string(),
            VideoRect::xywh(830.0, 201.0, w, h),
        )
    }

    // ----- SystemDialogDetector cases (the Swift `SystemDialogDetectorTests` suite cross-checks the same) -----

    // The HW-probed SecurityAgent password prompt → surfaced + flagged secure.
    #[test]
    fn security_agent_prompt_is_secure_dialog() {
        let d = classify_default(&snap(
            1966,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            true,
            260.0,
            312.0,
            "",
        ))
        .expect("SecurityAgent prompt surfaces");
        assert_eq!(d.window_id, 1966);
        assert_eq!(d.owner, "SecurityAgent");
        assert_eq!(d.width, 260);
        assert_eq!(d.height, 312);
        assert!(d.is_secure);
    }

    // Touch ID / LocalAuthentication agent — also secure.
    #[test]
    fn coreauthd_is_secure_dialog() {
        let d = classify_default(&snap(
            7,
            "coreauthd",
            "com.apple.coreauthd",
            true,
            260.0,
            312.0,
            "",
        ))
        .expect("coreauthd prompt surfaces");
        assert!(d.is_secure);
    }

    // Matched by OWNER NAME even when the bundle id is unexpected/blank (resilient across builds).
    #[test]
    fn owner_name_match_without_bundle() {
        assert!(classify_default(&snap(8, "SecurityAgent", "", true, 260.0, 312.0, "")).is_some());
    }

    // A normal app window (Chrome) is NOT a system dialog.
    #[test]
    fn regular_app_window_ignored() {
        assert!(classify_default(&snap(
            1783,
            "Google Chrome",
            "com.google.Chrome",
            true,
            700.0,
            500.0,
            "",
        ))
        .is_none());
    }

    // The SecurityAgent OFFSCREEN helper (onScreen=false, 500×500) must not surface.
    #[test]
    fn offscreen_helper_ignored() {
        assert!(classify_default(&snap(
            1967,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            false,
            500.0,
            500.0,
            "",
        ))
        .is_none());
    }

    // A sub-minSize same-owner sliver (an indicator) is rejected.
    #[test]
    fn tiny_window_ignored() {
        assert!(classify_default(&snap(
            9,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            true,
            20.0,
            20.0,
            "",
        ))
        .is_none());
    }

    // detect() filters a mixed snapshot down to just the system prompts, order preserved.
    #[test]
    fn detect_filters_mixed_snapshot() {
        let windows = vec![
            snap(
                1,
                "Google Chrome",
                "com.google.Chrome",
                true,
                700.0,
                500.0,
                "",
            ),
            snap(
                1966,
                "SecurityAgent",
                "com.apple.SecurityAgent",
                true,
                260.0,
                312.0,
                "",
            ),
            snap(
                1967,
                "SecurityAgent",
                "com.apple.SecurityAgent",
                false,
                500.0,
                500.0,
                "",
            ),
            snap(3, "Finder", "com.apple.finder", true, 900.0, 600.0, ""),
        ];
        let ids: Vec<u32> = detect_default(&windows)
            .iter()
            .map(|d| d.window_id)
            .collect();
        assert_eq!(
            ids,
            vec![1966],
            "only the visible SecurityAgent prompt surfaces"
        );
    }

    // ----- spec edge cases -----

    fn sa(id: u32, w: f64, h: f64) -> WindowSnapshot {
        snap(
            id,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            true,
            w,
            h,
            "",
        )
    }

    // Zero-area frame: rounds to 0 < MIN_SIZE → None, even for SecurityAgent.
    #[test]
    fn zero_area_frame_is_rejected() {
        assert!(classify_default(&sa(10, 0.0, 0.0)).is_none());
    }

    // Rounding boundary just PASSES: 59.5 → round half-away → 60 == MIN_SIZE → passes (>=).
    #[test]
    fn rounding_boundary_passes() {
        let d = classify_default(&sa(11, 59.5, 59.5)).expect("59.5 rounds up to 60 == MIN_SIZE");
        assert_eq!(d.width, 60);
        assert_eq!(d.height, 60);
    }

    // Rounding boundary just FAILS: 59.4 → 59 < 60 → None.
    #[test]
    fn rounding_boundary_fails() {
        assert!(classify_default(&sa(12, 59.4, 200.0)).is_none());
    }

    // Too-small height alone rejects: 30 → 30 < 60 → None.
    #[test]
    fn too_small_height_rejected() {
        assert!(classify_default(&sa(13, 400.0, 30.0)).is_none());
    }

    // Rounding 60.5 → 61 (half away from zero, NOT banker's 60).
    #[test]
    fn rounding_up_not_bankers() {
        let d = classify_default(&sa(14, 60.5, 60.5)).expect("rounds to 61");
        assert_eq!(d.width, 61);
        assert_eq!(d.height, 61);
    }

    // Exact integer fit at the threshold: 60×60, MIN_SIZE 60.
    #[test]
    fn exact_integer_fit() {
        let d = classify_default(&sa(15, 60.0, 60.0)).expect("60 == MIN_SIZE passes");
        assert_eq!(d.width, 60);
        assert_eq!(d.height, 60);
    }

    // Negative-dimension frame: CG standardizes → width()/height() = abs → Dialog{400,200}.
    #[test]
    fn negative_dimension_standardized() {
        let d = classify_default(&sa(16, -400.0, -200.0)).expect("CG standardizes to positive");
        assert_eq!(d.width, 400);
        assert_eq!(d.height, 200);
    }

    // Not on screen short-circuits to None regardless of owner/size.
    #[test]
    fn not_on_screen_short_circuits() {
        assert!(classify_default(&snap(
            17,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            false,
            400.0,
            200.0,
            "",
        ))
        .is_none());
    }

    // Empty owner name → label falls back to the bundle id.
    #[test]
    fn empty_owner_falls_back_to_bundle() {
        let d = classify_default(&snap(
            18,
            "",
            "com.apple.SecurityAgent",
            true,
            400.0,
            200.0,
            "",
        ))
        .expect("matched by bundle id");
        assert_eq!(d.owner, "com.apple.SecurityAgent");
        assert!(d.is_secure);
    }

    // Non-empty owner name wins over the bundle id (here bundle is empty).
    #[test]
    fn non_empty_owner_wins() {
        let d = classify_default(&snap(19, "SecurityAgent", "", true, 400.0, 200.0, ""))
            .expect("matched by owner name");
        assert_eq!(d.owner, "SecurityAgent");
        assert!(d.is_secure);
    }

    // coreauthd by bundle id with empty owner → label falls back to bundle id.
    #[test]
    fn coreauthd_by_bundle_empty_owner_label() {
        let d = classify_default(&snap(20, "", "com.apple.coreauthd", true, 400.0, 200.0, ""))
            .expect("matched by coreauthd bundle id");
        assert_eq!(d.owner, "com.apple.coreauthd");
        assert!(d.is_secure);
    }

    // Both owner_name AND bundle_id empty → never in any secure/system set → None.
    #[test]
    fn both_identifiers_empty_is_rejected() {
        assert!(classify_default(&snap(21, "", "", true, 400.0, 200.0, "")).is_none());
    }

    // Custom min_size rejects an 80×80 SecurityAgent.
    #[test]
    fn custom_min_size_rejects() {
        assert!(classify(&sa(22, 80.0, 80.0), 100).is_none());
    }

    // Custom min_size admits a 120×120 SecurityAgent.
    #[test]
    fn custom_min_size_accepts() {
        let d = classify(&sa(23, 120.0, 120.0), 100).expect("120 >= 100");
        assert_eq!(d.width, 120);
        assert_eq!(d.height, 120);
    }

    // min_size=0 admits any positive-rounded size (1×1).
    #[test]
    fn min_size_zero_admits_small() {
        let d = classify(&sa(24, 1.0, 1.0), 0).expect("1 >= 0");
        assert_eq!(d.width, 1);
        assert_eq!(d.height, 1);
    }

    // Negative min_size admits everything on-screen (width is non-negative ≥ negative always).
    #[test]
    fn negative_min_size_admits_everything_on_screen() {
        assert!(classify(&sa(25, 1.0, 1.0), -5).is_some());
    }

    // Multibyte/Unicode title passes through byte-exact.
    #[test]
    fn unicode_title_passes_through() {
        let title = "Authenticate · 認証 🔐";
        let d = classify_default(&snap(
            26,
            "SecurityAgent",
            "com.apple.SecurityAgent",
            true,
            400.0,
            200.0,
            title,
        ))
        .expect("surfaces");
        assert_eq!(d.title, title);
    }

    // detect: empty input → empty Vec.
    #[test]
    fn detect_empty_input() {
        assert_eq!(detect_default(&[]), Vec::<Dialog>::new());
    }

    // detect: all-rejected input → empty Vec.
    #[test]
    fn detect_all_rejected() {
        let windows = vec![
            snap(
                1,
                "Google Chrome",
                "com.google.Chrome",
                true,
                700.0,
                500.0,
                "",
            ),
            snap(2, "Finder", "com.apple.finder", true, 900.0, 600.0, ""),
        ];
        assert_eq!(detect_default(&windows), Vec::<Dialog>::new());
    }

    // ----- keystrokes_blocked policy (live Secure-Event-Input, NOT the static class) -----

    // The real login/unlock prompt: secure class + Secure Event Input live + no virtual HID → blocked.
    #[test]
    fn keystrokes_blocked_when_secure_and_sei_active() {
        assert!(keystrokes_blocked(true, true, false));
    }

    // The `do shell script with admin` prompt: secure CLASS but Secure Event Input NOT active →
    // synthetic typing lands → NOT blocked (the badge fix: no false "view-only").
    #[test]
    fn keystrokes_not_blocked_when_sei_inactive() {
        assert!(!keystrokes_blocked(true, false, false));
    }

    // A virtual-HID keyboard bypasses Secure Event Input → typable even with SEI live → not blocked.
    #[test]
    fn keystrokes_not_blocked_when_virtual_hid_available() {
        assert!(!keystrokes_blocked(true, true, true));
    }

    // A non-secure dialog is never input-blocked regardless of the live state.
    #[test]
    fn keystrokes_not_blocked_for_non_secure_dialog() {
        assert!(!keystrokes_blocked(false, true, false));
        assert!(!keystrokes_blocked(false, false, false));
    }

    // detect: mixed input → accepts in original index order (filter only).
    #[test]
    fn detect_preserves_order_with_multiple_accepts() {
        let windows = vec![
            snap(
                30,
                "SecurityAgent",
                "com.apple.SecurityAgent",
                true,
                400.0,
                200.0,
                "",
            ),
            snap(
                31,
                "Google Chrome",
                "com.google.Chrome",
                true,
                800.0,
                600.0,
                "",
            ),
            snap(
                32,
                "SecurityAgent",
                "com.apple.SecurityAgent",
                true,
                50.0,
                50.0,
                "",
            ),
            snap(33, "coreauthd", "", true, 300.0, 150.0, ""),
        ];
        let ids: Vec<u32> = detect_default(&windows)
            .iter()
            .map(|d| d.window_id)
            .collect();
        assert_eq!(
            ids,
            vec![30, 33],
            "accepts in input order, rejects filtered out"
        );
    }
}
