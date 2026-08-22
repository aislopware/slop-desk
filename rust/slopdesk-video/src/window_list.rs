//! The frontmost-app election over a `CGWindowListCopyWindowInfo` answer — was
//! `Sources/SlopDeskVideoHost/HostFrontmostApp.swift`'s pure half.
//!
//! `rust/slopdesk-apple-cgwindow` asks the WindowServer and decodes one record at a time; this
//! module says what a record means. Keeping the rule here rather than in the Apple crate is the
//! same split `input_routing` and `slopdesk-apple-cgevent` already take: the crate that touches a
//! framework makes no decisions, and the crate that makes decisions never touches a framework.
//!
//! ## Why the frontmost app is elected from the window list at all
//!
//! `NSWorkspace.shared.frontmostApplication` is a per-process SNAPSHOT: it populates on first
//! access and then updates only through AppKit run-loop machinery a daemon never pumps. Every later
//! read answers the first-access app forever — probe-verified, with Chrome frontmost, a daemon
//! launched from Terminal read `com.apple.Terminal` on every call, on and off the main thread,
//! while a side-by-side window-list scan tracked Chrome→Finder→Chrome live. That freeze made the
//! swipe-nav status push report `eligible=false` for the daemon's whole life.

/// One on-screen window's routing-relevant fields, as decoded from a window-list record. `None` in
/// a field means the record was missing or malformed it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FrontmostCandidate {
    /// The CG window level. Only `0` — an ordinary app window — can elect.
    pub layer: Option<i32>,
    /// The owning process.
    pub owner_pid: Option<i32>,
    /// The window's alpha. A fully transparent window is not on screen in any sense that matters.
    pub alpha: Option<f64>,
}

/// The per-record rule: a FULLY described window at normal level with any visible alpha elects its
/// owner.
///
/// Validate-then-drop. A record missing a field never elects — a malformed record electing a
/// frontmost app is how a daemon ends up injecting into the wrong process.
#[must_use]
pub fn elected_owner_pid(window: FrontmostCandidate) -> Option<i32> {
    let layer = window.layer?;
    let pid = window.owner_pid?;
    let alpha = window.alpha?;
    (layer == 0 && pid > 0 && alpha > 0.0).then_some(pid)
}

/// The rule over a front-to-back list: the first electing record wins.
///
/// The real caller does not build the list — it decodes records one at a time and stops here, which
/// is why this exists mainly to be tested. Both spellings agree by construction.
#[must_use]
pub fn frontmost_owner_pid(windows: &[FrontmostCandidate]) -> Option<i32> {
    windows.iter().copied().find_map(elected_owner_pid)
}

#[cfg(test)]
mod tests {
    use super::{FrontmostCandidate, elected_owner_pid, frontmost_owner_pid};

    fn window(layer: Option<i32>, pid: Option<i32>, alpha: Option<f64>) -> FrontmostCandidate {
        FrontmostCandidate {
            layer,
            owner_pid: pid,
            alpha,
        }
    }

    fn normal(pid: i32) -> FrontmostCandidate {
        window(Some(0), Some(pid), Some(1.0))
    }

    /// The first normal-level, visible window elects, and the ones behind it do not get a say.
    #[test]
    fn the_frontmost_normal_window_elects_its_owner() {
        let pid = frontmost_owner_pid(&[
            window(Some(25), Some(11), Some(1.0)),
            normal(200),
            normal(300),
        ]);
        assert_eq!(pid, Some(200));
    }

    /// Overlay levels and invisible windows are skipped rather than electing — a menu bar at layer
    /// 24 or a fully transparent helper must never be read as "the app the user is in".
    #[test]
    fn overlays_and_transparent_windows_are_skipped() {
        let pid = frontmost_owner_pid(&[
            window(Some(24), Some(11), Some(1.0)),
            window(Some(0), Some(12), Some(0.0)),
            window(Some(101), Some(13), Some(1.0)),
            normal(400),
        ]);
        assert_eq!(pid, Some(400));
    }

    /// Validate-then-drop, one field at a time.
    #[test]
    fn a_record_missing_any_field_never_elects() {
        assert_eq!(elected_owner_pid(window(None, Some(1), Some(1.0))), None);
        assert_eq!(elected_owner_pid(window(Some(0), None, Some(1.0))), None);
        assert_eq!(elected_owner_pid(window(Some(0), Some(1), None)), None);
        assert_eq!(elected_owner_pid(window(Some(0), Some(0), Some(1.0))), None);
    }

    /// No windows at all — the lock screen, a sleeping display — is `None`, and every caller reads
    /// that as "not eligible" rather than guessing.
    #[test]
    fn an_empty_or_wholly_ineligible_list_answers_nothing() {
        assert_eq!(frontmost_owner_pid(&[]), None);
        assert_eq!(
            frontmost_owner_pid(&[window(Some(8), Some(1), Some(1.0)), window(Some(0), Some(2), Some(0.0))]),
            None
        );
    }

    /// A NaN alpha is not a visible window. `alpha > 0.0` is false for NaN, which is the answer
    /// this wants — the guard is written as a comparison, not as a negated one.
    #[test]
    fn a_nan_alpha_does_not_elect() {
        assert_eq!(elected_owner_pid(window(Some(0), Some(5), Some(f64::NAN))), None);
    }
}
