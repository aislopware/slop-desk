//! Which enumerated windows are host SYSTEM dialogs.
//!
//! A system dialog is a cross-process modal window no app pane would ever capture — the prime case
//! being a `SecurityAgent` login/admin password prompt. The host enumerates on-screen windows, runs
//! this classifier, and answers the client's `listSystemDialogs` poll with the matches.
//!
//! **DORMANT** (`docs/DECISIONS.md`, 2026-07-23): the system-dialog pane that consumed this was
//! removed and no runtime caller remains. What keeps it alive is the wire — the
//! `listSystemDialogs`/`systemDialogList` verb pair is kept allocated so a client built against it
//! cannot have its number reused, and `golden/golden_vectors.json` pins `systemDialogClassify` and
//! `systemDialogDetect` byte for byte. A dormant rule whose vectors are pinned is still a rule; it
//! is the pins that must not drift, not the caller that must exist.
//!
//! ## Hardware-grounded, and the flag does not mean what it looks like (Tahoe 26.5.1)
//!
//! `SCShareableContent` DOES list the `SecurityAgent` prompt — own window, layer 1000, on screen —
//! and `desktopIndependentWindow` captures it with real pixels, so it is not capture-blocked. While
//! it is up, `IsSecureEventInputEnabled()` reads true, and that still does NOT block injection: the
//! host's `CGEvent` keystrokes land in the field, it fills with dots, and it authenticates. So
//! [`Dialog::is_secure`] flags a secure-CREDENTIAL prompt — for the client's paste guard and its
//! "Secure prompt" chip — and never a view-only restriction. Reading it as "cannot type here" would
//! invert the one behaviour that was measured on hardware.
//!
//! ## Scope, and why the allowlists are empty in one direction
//!
//! System AUTH prompts only: `SecurityAgent` and `coreauthd`. Those never overlap a streamed app
//! window — different system pid, never a child of an app window — and never overlap the
//! dialog-expand union, which folds app-OWNED save/open panels into the streamed pane already.
//! Surfacing an app-owned panel here would double it up, which is why [`SYSTEM_BUNDLE_IDS`] and
//! [`SYSTEM_OWNER_NAMES`] are deliberately empty rather than absent: they are the expansion point
//! for a future standalone system alert, and an entry each is the whole cost of adding one.
//!
//! ## The float order is load-bearing, and the SIGN is not the caller's
//!
//! The corpus carries the frame's width and height as BIT PATTERNS, so the arithmetic below is
//! pinned exactly as spelled. Three things in it are load-bearing and none is obvious:
//!
//! - the extent is taken as a MAGNITUDE. The near side read `CGRect.width`, which is documented to
//!   answer the STANDARDIZED extent — a rect built with a negative size describes the same region
//!   walked the other way, and `width` reports it positive. `negativeSizeStandardizes` pins exactly
//!   that: a −400 × −200 frame classifies as 400 × 200, not as a sub-floor rejection. Reading the
//!   raw component instead would silently drop a real prompt.
//! - rounding is ties-AWAY-from-zero, matching `CGFloat.rounded()`'s default rule. `roundingUp605`
//!   pins 60.5 → 61, which ties-to-even would answer 60.
//! - the floor compares the ROUNDED integer, not the float. `roundingPasses595` pins 59.5 as a PASS
//!   at a floor of 60, and `roundingFails594` pins 59.4 as a rejection; gating before rounding
//!   would reject both.

/// Secure auth processes — password and credential prompts.
///
/// Matched by bundle id OR owner name, and both are carried because the two disagree in practice: a
/// `SecurityAgent` window can arrive with an empty bundle id, so the NAME is the resilient signal
/// across macOS builds. The window server gives both, so both are asked.
pub const SECURE_BUNDLE_IDS: &[&str] = &["com.apple.SecurityAgent", "com.apple.coreauthd"];

/// The owner-name spelling of [`SECURE_BUNDLE_IDS`].
pub const SECURE_OWNER_NAMES: &[&str] = &["SecurityAgent", "coreauthd"];

/// Non-secure system-prompt sources — view plus FULL interaction. Empty in v1, on purpose; see the
/// module docs.
pub const SYSTEM_BUNDLE_IDS: &[&str] = &[];

/// The owner-name spelling of [`SYSTEM_BUNDLE_IDS`]. Empty in v1, on purpose.
pub const SYSTEM_OWNER_NAMES: &[&str] = &[];

/// Windows smaller than this in EITHER dimension are never dialogs.
///
/// Offscreen helpers and 1×1 indicators sit well under it and a real prompt sits well over it, so
/// the floor separates them with room to spare rather than discriminating near a boundary.
pub const MIN_SIZE: i64 = 60;

/// One enumerated on-screen window, as the classifier reads it.
///
/// Built from an `SCWindow` on the host and kept a plain value so the rule is pure and testable off
/// device — the whole point of the split this crate takes from `slopdesk-apple-sck`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WindowSnapshot<'a> {
    /// The `CGWindowID`.
    pub window_id: u32,
    /// The owning process's display name.
    pub owner_name: &'a str,
    /// The owning application's bundle identifier, which may be empty.
    pub bundle_id: &'a str,
    /// Whether the window server calls it on screen.
    pub is_on_screen: bool,
    /// The window title, which is empty for most auth prompts.
    pub title: &'a str,
    /// The frame width in points.
    pub width: f64,
    /// The frame height in points.
    pub height: f64,
}

/// A classified system dialog. The shape mirrors the wire's `SystemDialogSummary`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dialog {
    /// The `CGWindowID` to capture.
    pub window_id: u32,
    /// The owner name, falling back to the bundle id when the name is empty.
    pub owner: String,
    /// The window title, verbatim.
    pub title: String,
    /// The rounded frame width in points.
    pub width: i64,
    /// The rounded frame height in points.
    pub height: i64,
    /// A secure-credential prompt. See the module docs — this is NOT a typing restriction.
    pub is_secure: bool,
}

/// Classify one window, or `None` when it is not a surfaced system dialog.
///
/// The order is load-bearing and pinned: round, then gate on the ROUNDED size, then decide the
/// class. A rule that gated on the raw float would answer differently for a 59.6-point window than
/// the corpus records.
#[must_use]
pub fn classify(window: &WindowSnapshot<'_>, min_size: i64) -> Option<Dialog> {
    let width = round_points(window.width);
    let height = round_points(window.height);
    if !window.is_on_screen || width < min_size || height < min_size {
        return None;
    }

    let is_secure =
        SECURE_BUNDLE_IDS.contains(&window.bundle_id) || SECURE_OWNER_NAMES.contains(&window.owner_name);
    let is_system = is_secure
        || SYSTEM_BUNDLE_IDS.contains(&window.bundle_id)
        || SYSTEM_OWNER_NAMES.contains(&window.owner_name);
    if !is_system {
        return None;
    }

    // The bundle id is the fallback because an empty OWNER name is the case that happens; an empty
    // bundle id with a real name is the commoner one, and the name is what a person recognises.
    let owner = if window.owner_name.is_empty() {
        window.bundle_id
    } else {
        window.owner_name
    };
    Some(Dialog {
        window_id: window.window_id,
        owner: owner.to_owned(),
        title: window.title.to_owned(),
        width,
        height,
        is_secure,
    })
}

/// Classify a whole snapshot into the dialogs to surface, in the order given.
///
/// Order is preserved rather than sorted: the window server answers front to back, and the client
/// spawns a pane per entry, so re-ordering would reshuffle panes between two polls that saw the
/// same screen.
#[must_use]
pub fn detect(windows: &[WindowSnapshot<'_>], min_size: i64) -> Vec<Dialog> {
    windows
        .iter()
        .filter_map(|window| classify(window, min_size))
        .collect()
}

/// A frame extent to whole points: MAGNITUDE first, then ties away from zero, saturating.
///
/// `abs` before `round` is the `CGRect.width` contract, not a defensive flourish — see the module
/// docs and the `negativeSizeStandardizes` vector. Taking it after would round −400.5 to −401 and
/// then report 401.
///
/// `as` on a NaN answers 0 and on an out-of-range float saturates, which is the behaviour wanted at
/// both ends: a window server that answered NaN for a frame has already lost, and 0 fails the size
/// floor rather than classifying something unmeasurable as a password prompt.
#[expect(
    clippy::cast_possible_truncation,
    reason = "`as` saturates at the i64 bounds and sends NaN to 0, which is the wanted behaviour for a \
              frame extent the window server could not measure"
)]
const fn round_points(value: f64) -> i64 {
    value.abs().round() as i64
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Dialog, MIN_SIZE, WindowSnapshot, classify, detect};

    fn secure_agent() -> WindowSnapshot<'static> {
        WindowSnapshot {
            window_id: 1966,
            owner_name: "SecurityAgent",
            bundle_id: "com.apple.SecurityAgent",
            is_on_screen: true,
            title: "",
            width: 260.0,
            height: 312.0,
        }
    }

    #[test]
    fn a_security_agent_prompt_is_a_secure_dialog() {
        let dialog = classify(&secure_agent(), MIN_SIZE).expect("classified");
        assert_eq!(dialog, Dialog {
            window_id: 1966,
            owner: "SecurityAgent".to_owned(),
            title: String::new(),
            width: 260,
            height: 312,
            is_secure: true,
        });
    }

    /// The name is the resilient signal: a prompt whose bundle id the window server left empty is
    /// still a prompt.
    #[test]
    fn the_owner_name_alone_is_enough() {
        let window = WindowSnapshot {
            bundle_id: "",
            ..secure_agent()
        };
        assert!(classify(&window, MIN_SIZE).is_some_and(|d| d.is_secure));
    }

    /// And the bundle id alone is enough too, with the id standing in as the label.
    #[test]
    fn an_empty_owner_name_falls_back_to_the_bundle_id() {
        let window = WindowSnapshot {
            owner_name: "",
            ..secure_agent()
        };
        let dialog = classify(&window, MIN_SIZE).expect("classified");
        assert_eq!(dialog.owner, "com.apple.SecurityAgent");
    }

    #[test]
    fn an_ordinary_app_window_is_not_a_dialog() {
        let window = WindowSnapshot {
            owner_name: "Google Chrome",
            bundle_id: "com.google.Chrome",
            ..secure_agent()
        };
        assert_eq!(classify(&window, MIN_SIZE), None);
    }

    #[test]
    fn an_offscreen_prompt_is_not_surfaced() {
        let window = WindowSnapshot {
            is_on_screen: false,
            ..secure_agent()
        };
        assert_eq!(classify(&window, MIN_SIZE), None);
    }

    #[test]
    fn a_sub_floor_window_is_not_surfaced() {
        let window = WindowSnapshot {
            width: 20.0,
            height: 20.0,
            ..secure_agent()
        };
        assert_eq!(classify(&window, MIN_SIZE), None);
    }

    /// The floor is compared against the ROUNDED size, so a window that rounds UP to the floor
    /// passes. Rounding after the gate would drop it.
    #[test]
    fn the_size_gate_reads_the_rounded_value() {
        let window = WindowSnapshot {
            width: 59.6,
            height: 59.6,
            ..secure_agent()
        };
        let dialog = classify(&window, MIN_SIZE).expect("59.6 rounds to 60");
        assert_eq!((dialog.width, dialog.height), (60, 60));
    }

    /// Ties round AWAY from zero, matching `CGFloat.rounded()`'s default rule.
    #[test]
    fn a_half_point_rounds_away_from_zero() {
        let window = WindowSnapshot {
            width: 260.5,
            height: 312.5,
            ..secure_agent()
        };
        let dialog = classify(&window, MIN_SIZE).expect("classified");
        assert_eq!((dialog.width, dialog.height), (261, 313));
    }

    /// A rect built with a negative size describes the same region walked the other way, and the
    /// near side's `CGRect.width` reports it POSITIVE. Reading the raw component would reject a
    /// real prompt as sub-floor.
    #[test]
    fn a_negative_frame_standardizes_to_its_magnitude() {
        let window = WindowSnapshot {
            width: -400.0,
            height: -200.0,
            ..secure_agent()
        };
        let dialog = classify(&window, MIN_SIZE).expect("a negative extent is still an extent");
        assert_eq!((dialog.width, dialog.height), (400, 200));
    }

    /// A frame the window server could not measure fails the floor rather than classifying.
    #[test]
    fn a_nan_frame_is_not_a_dialog() {
        let window = WindowSnapshot {
            width: f64::NAN,
            height: f64::NAN,
            ..secure_agent()
        };
        assert_eq!(classify(&window, MIN_SIZE), None);
    }

    #[test]
    fn detect_keeps_the_order_it_was_given_and_drops_the_rest() {
        let chrome = WindowSnapshot {
            window_id: 1,
            owner_name: "Google Chrome",
            bundle_id: "com.google.Chrome",
            ..secure_agent()
        };
        let offscreen = WindowSnapshot {
            window_id: 1967,
            is_on_screen: false,
            ..secure_agent()
        };
        let coreauthd = WindowSnapshot {
            window_id: 7,
            owner_name: "coreauthd",
            bundle_id: "com.apple.coreauthd",
            ..secure_agent()
        };
        let dialogs = detect(&[chrome, secure_agent(), offscreen, coreauthd], MIN_SIZE);
        let ids: Vec<u32> = dialogs.iter().map(|d| d.window_id).collect();
        assert_eq!(ids, vec![1966, 7]);
    }

    #[test]
    fn an_empty_snapshot_yields_nothing() {
        assert!(detect(&[], MIN_SIZE).is_empty());
    }
}
