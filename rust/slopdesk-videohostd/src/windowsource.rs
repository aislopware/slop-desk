//! The host's windows, as the feed's input shape.
//!
//! One census of the window server per tick, turned into the `Vec<WindowFeedSourceWindow>` that
//! [`slopdesk_video::window_feed_host::snapshot_records`] takes. Every RULE over those records —
//! the inclusion policy, the excluded-app list, the minimum dimension, the byte caps, the focused
//! bit, the record cap — is that module's and is golden-pinned; this file is the read.
//!
//! ## What it replaces, and what dissolved on the way
//! `WindowFeedSnapshotBuilder.swift` and `WindowFeedGlue.swift`'s `enumerateHostWindows`. The
//! builder was a pure FFI face: a `WindowFeedSourceWindow` whose three strings were INTERNED into a
//! `Data` arena, a `SlopDeskByteSpan` per string, and a two-call shape-then-fill protocol over
//! `slopdesk_feed_snapshot`. All of that existed because a `String` cannot cross a C boundary.
//! `snapshot_records` takes owned `String`s and answers owned `String`s, so the arena, the spans
//! and the two-call protocol are not ported — they are DELETED. `docs/55` §4c is the measurement
//! that says so: a crossing is about a nanosecond and what costs is the marshalling, so the
//! marshalling is the only thing the arena ever bought, and there is no boundary here to buy it
//! for.
//!
//! ## The one thing here that IS a decision, and is reported as such
//! [`display_ordinal`]. `slopdesk_video` holds the argmax-by-overlap SHAPE twice — `VideoRect`'s
//! own `intersection_area`, and `coordinate_mapping::backing_scale_factor`'s loop over it — but
//! neither answers an ORDINAL, and `window_list::display_for_window_frame` answers a rect on
//! different terms (centre-containing first). The Swift computed it inline in the glue, not behind
//! a door, and the wire field is a `u8` nothing pins. Shipping `0` for every window would be a
//! silent feed regression, so it is written here with the tie-break pinned by a test — and it is
//! the first line of this port's findings, as a candidate for promotion into `window_feed_host`
//! next round.

use core::fmt;

use slopdesk_video::geometry::VideoRect;
use slopdesk_video::window_feed_host::WindowFeedSourceWindow;

use crate::windowprobe::{OffScreenProbe, OffScreenWindow, SweepsApps};

/// The CG window level an ordinary application window sits at. Everything else the census answers —
/// menus at 101, the menu bar at 24, the Dock, tooltips — is furniture, not a window a person
/// switches to.
pub const APP_WINDOW_LAYER: i32 = 0;

/// One window as the window server describes it, with the two per-application facts the feed also
/// needs. The shape the rest of this module reads, and the seam a test writes.
#[derive(Clone, Debug, PartialEq)]
pub struct SourceRow {
    /// The `CGWindowID`.
    pub window_id: u32,
    /// The owning process.
    pub owner_pid: i32,
    /// The CG window level.
    pub layer: i32,
    /// The frame in CG global top-left points.
    pub bounds: VideoRect,
    /// `kCGWindowOwnerName`, or empty when the server did not say.
    pub owner_name: String,
    /// `kCGWindowName`, or empty — absent for an untitled window AND for every window on a machine
    /// without the Screen Recording grant.
    pub title: String,
    /// Whether the window server is currently drawing it.
    pub is_on_screen: bool,
}

/// Reading the desktop: the census, the frontmost app, the displays, and the two per-pid facts.
///
/// One trait rather than four, because a test substitutes a whole DESKTOP and a half-substituted
/// one is a fixture that cannot be reasoned about. Every method here needs a window server, TCC, or
/// both, which is the reason the seam exists at all.
pub trait ReadsDesktop: Send + Sync + fmt::Debug {
    /// Every window the server knows about, on screen or not, desktop elements excluded.
    fn census(&self) -> Vec<SourceRow>;
    /// The pid of the frontmost application, elected from the window list. `None` on a locked or
    /// sleeping screen.
    fn frontmost_pid(&self) -> Option<i32>;
    /// Every ACTIVE display's bounds, in the same CG global top-left space the census answers in.
    fn display_bounds(&self) -> Vec<VideoRect>;
    /// The application's bundle identifier, or `None` when it has none.
    fn bundle_id(&self, pid: i32) -> Option<String>;
    /// Whether the application is hidden (⌘H), which is not the same as its windows being
    /// off-screen.
    fn is_hidden(&self, pid: i32) -> bool;
}

/// The real desktop, through the three `slopdesk-apple-*` read crates.
#[derive(Clone, Copy, Debug, Default)]
pub struct HostDesktop;

impl ReadsDesktop for HostDesktop {
    fn census(&self) -> Vec<SourceRow> {
        slopdesk_apple_cgwindow::census()
            .into_iter()
            .map(|row| {
                SourceRow {
                    window_id: row.window.window_id,
                    owner_pid: row.window.owner_pid,
                    layer: row.window.layer,
                    bounds: row.window.bounds,
                    owner_name: row.owner_name.unwrap_or_default(),
                    title: row.title.unwrap_or_default(),
                    is_on_screen: row.is_on_screen,
                }
            })
            .collect()
    }

    /// Elected from the window list, NEVER `NSWorkspace.frontmostApplication`.
    ///
    /// The reason is written in `slopdesk-apple-cgwindow` and is worth repeating at the caller: in
    /// a daemon that pumps no `AppKit` run loop the workspace read freezes at its first access,
    /// and this field named the wrong app for the daemon's whole life.
    fn frontmost_pid(&self) -> Option<i32> {
        slopdesk_apple_cgwindow::frontmost_pid()
    }

    fn display_bounds(&self) -> Vec<VideoRect> {
        slopdesk_apple_cgdisplay::active()
            .into_iter()
            .map(|display| display.bounds)
            .collect()
    }

    fn bundle_id(&self, pid: i32) -> Option<String> {
        slopdesk_apple_app::bundle_id(pid)
    }

    fn is_hidden(&self, pid: i32) -> bool {
        slopdesk_apple_app::is_hidden(pid)
    }
}

/// Which display a window is MOSTLY on, as an index into `displays`.
///
/// The largest intersection area wins, with a STRICT comparison so an exact tie keeps the EARLIER
/// display — `coordinate_mapping::backing_scale_factor`'s loop, and Swift's `max(by:)`, decide a
/// tie the same way, and a window straddling two identically-sized screens is the case that hits
/// it. `0` when there are no displays, which is what a query failure answers, and the index is
/// saturated into the wire's `u8` rather than wrapped.
#[must_use]
pub fn display_ordinal(bounds: VideoRect, displays: &[VideoRect]) -> u8 {
    let mut best = 0_usize;
    let mut best_area = f64::NEG_INFINITY;
    for (index, display) in displays.iter().enumerate() {
        let area = display.intersection_area(&bounds);
        if area > best_area {
            best_area = area;
            best = index;
        }
    }
    u8::try_from(best).unwrap_or(u8::MAX)
}

/// A CG point extent as the wire's integer point count.
///
/// ROUNDED, not truncated — `Int(bounds.width.rounded())` is what the Swift wrote, and the
/// difference shows on every window whose frame is on a half point, which on a Retina desktop is
/// most of them. A non-finite or out-of-range extent answers `0`, which the inclusion policy's
/// minimum-dimension gate then drops.
#[must_use]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the clamp above the cast is what makes it exact; there is no checked float-to-int"
)]
pub fn points(value: f64) -> i32 {
    let rounded = value.round();
    if rounded.is_nan() {
        // A NaN extent is a window the server could not measure. Zero is the honest answer and the
        // inclusion gate drops it; a clamp would publish a window the width of the wire's ceiling.
        return 0;
    }
    // Clamped BEFORE the cast, so an infinity — which a detached display can produce for a frame —
    // saturates rather than becoming implementation-defined.
    rounded.clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}

/// The whole desktop, as the feed's input, at `now`.
///
/// The order is load-bearing and is the Swift's: the ON-SCREEN block first, in the front-to-back
/// order the window server answers it in, then everything else. `CGWindowList` promises z-order
/// only among on-screen windows, so partitioning is what keeps the half that is promised — and the
/// focused-window bit `snapshot_records` sets reads the FIRST on-screen window of the frontmost app
/// in that order, so a shuffled list would mark the wrong window focused.
///
/// The per-pid reads are cached within ONE enumeration, because an app owns many windows: that is
/// what keeps two framework calls per window down to two per app.
pub fn enumerate<D: ReadsDesktop, S: SweepsApps>(
    desktop: &D,
    probe: &OffScreenProbe<S>,
    now: f64,
) -> Vec<WindowFeedSourceWindow> {
    let frontmost = desktop.frontmost_pid();
    let displays = desktop.display_bounds();
    let mut app_state: Vec<(i32, String, bool)> = Vec::new();

    let mut on_screen: Vec<WindowFeedSourceWindow> = Vec::new();
    let mut off_screen: Vec<WindowFeedSourceWindow> = Vec::new();
    let mut off_screen_windows: Vec<OffScreenWindow> = Vec::new();

    for row in desktop.census() {
        if row.layer != APP_WINDOW_LAYER {
            continue;
        }
        let cached = app_state.iter().position(|(pid, ..)| *pid == row.owner_pid);
        let index = cached.unwrap_or_else(|| {
            app_state.push((
                row.owner_pid,
                desktop.bundle_id(row.owner_pid).unwrap_or_default(),
                desktop.is_hidden(row.owner_pid),
            ));
            app_state.len() - 1
        });
        let Some((_, bundle_id, is_hidden)) = app_state.get(index) else {
            continue;
        };
        let window = WindowFeedSourceWindow {
            window_id: row.window_id,
            owner_name: row.owner_name,
            bundle_id: bundle_id.clone(),
            layer: row.layer,
            is_on_screen: row.is_on_screen,
            title: row.title,
            width_pt: points(row.bounds.size.width),
            height_pt: points(row.bounds.size.height),
            display_index: display_ordinal(row.bounds, &displays),
            is_app_hidden: *is_hidden,
            is_frontmost_app: frontmost == Some(row.owner_pid),
            // Both resolved below, by the budgeted probe, and only for the off-screen block.
            is_minimized: false,
            is_ax_listed: false,
        };
        if row.is_on_screen {
            on_screen.push(window);
        } else {
            off_screen_windows.push(OffScreenWindow {
                window_id: row.window_id,
                pid: row.owner_pid,
            });
            off_screen.push(window);
        }
    }

    if !off_screen_windows.is_empty() {
        let verdict = probe.classify(&off_screen_windows, now);
        for window in &mut off_screen {
            window.is_minimized = verdict.minimized.binary_search(&window.window_id).is_ok();
            window.is_ax_listed = verdict.ax_listed.binary_search(&window.window_id).is_ok();
        }
    }

    on_screen.append(&mut off_screen);
    on_screen
}

/// A desktop and a probe, wired together — what the feed differ actually holds.
///
/// A type rather than two fields on the service, because the probe's budget must survive between
/// ticks: a fresh one per tick would sweep every stale pid every second and the cap would mean
/// nothing.
pub struct WindowSource<D: ReadsDesktop, S: SweepsApps> {
    /// Where the census comes from.
    desktop: D,
    /// The off-screen classifier, and the budget and ledger it carries between ticks.
    probe: OffScreenProbe<S>,
}

impl<D: ReadsDesktop, S: SweepsApps> fmt::Debug for WindowSource<D, S> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WindowSource")
            .field("desktop", &self.desktop)
            .field("probe", &self.probe)
            .finish()
    }
}

impl<D: ReadsDesktop, S: SweepsApps> WindowSource<D, S> {
    /// A source over `desktop`, classifying its off-screen windows with `sweeper`.
    pub fn new(desktop: D, sweeper: S) -> Self {
        Self {
            desktop,
            probe: OffScreenProbe::new(sweeper),
        }
    }

    /// One enumeration, at `now`.
    pub fn enumerate(&self, now: f64) -> Vec<WindowFeedSourceWindow> {
        enumerate(&self.desktop, &self.probe, now)
    }
}

/// The real one: the window server, the accessibility tree, and the three read crates between them.
#[must_use]
pub fn host_source() -> WindowSource<HostDesktop, crate::windowprobe::AccessibilityTree> {
    WindowSource::new(HostDesktop, crate::windowprobe::AccessibilityTree)
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::VideoRect;

    use super::{HostDesktop, ReadsDesktop, SourceRow, WindowSource, display_ordinal, points};
    use crate::windowprobe::SweepsApps;

    /// A whole desktop, written down.
    #[derive(Debug)]
    struct Fixture {
        rows: Vec<SourceRow>,
        frontmost: Option<i32>,
        displays: Vec<VideoRect>,
        hidden: Vec<i32>,
    }

    impl ReadsDesktop for Fixture {
        fn census(&self) -> Vec<SourceRow> {
            self.rows.clone()
        }
        fn frontmost_pid(&self) -> Option<i32> {
            self.frontmost
        }
        fn display_bounds(&self) -> Vec<VideoRect> {
            self.displays.clone()
        }
        fn bundle_id(&self, pid: i32) -> Option<String> {
            Some(format!("com.example.p{pid}"))
        }
        fn is_hidden(&self, pid: i32) -> bool {
            self.hidden.contains(&pid)
        }
    }

    /// An accessibility tree that lists everything it is asked about.
    #[derive(Debug)]
    struct ListsEverything;

    impl SweepsApps for ListsEverything {
        fn sweep(&self, pid: i32) -> Option<Vec<(u32, bool)>> {
            Some(vec![(pid.cast_unsigned(), true)])
        }
    }

    fn row(id: u32, pid: i32, layer: i32, on_screen: bool, bounds: VideoRect) -> SourceRow {
        SourceRow {
            window_id: id,
            owner_pid: pid,
            layer,
            bounds,
            owner_name: "Example".to_owned(),
            title: "A window".to_owned(),
            is_on_screen: on_screen,
        }
    }

    /// The window with the most overlap wins.
    #[test]
    fn a_window_belongs_to_the_display_it_overlaps_most() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            VideoRect::xywh(100.0, 0.0, 100.0, 100.0),
        ];
        assert_eq!(
            display_ordinal(VideoRect::xywh(80.0, 0.0, 60.0, 10.0), &displays),
            1
        );
        assert_eq!(
            display_ordinal(VideoRect::xywh(-10.0, 0.0, 60.0, 10.0), &displays),
            0
        );
    }

    /// The tie-break, pinned: an exact tie keeps the EARLIER display, because the comparison is
    /// strict. Swift's `max(by:)` and `coordinate_mapping`'s own loop both decide it this way, and
    /// a window centred on the seam between two identical screens is what hits it.
    #[test]
    fn an_exact_tie_keeps_the_earlier_display() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            VideoRect::xywh(100.0, 0.0, 100.0, 100.0),
        ];
        assert_eq!(
            display_ordinal(VideoRect::xywh(50.0, 0.0, 100.0, 10.0), &displays),
            0
        );
    }

    /// A window on NO display, and a desktop with no displays at all, both answer zero — the value
    /// the wire field defaults to, and the one the client's rail already handles.
    #[test]
    fn a_window_on_no_display_answers_the_first_one() {
        let displays = [VideoRect::xywh(0.0, 0.0, 100.0, 100.0)];
        assert_eq!(
            display_ordinal(VideoRect::xywh(500.0, 500.0, 10.0, 10.0), &displays),
            0
        );
        assert_eq!(display_ordinal(VideoRect::xywh(0.0, 0.0, 10.0, 10.0), &[]), 0);
    }

    /// The extent is ROUNDED to the nearest point, never truncated. A 1279.5-point window is 1280
    /// wide on the wire, which is what the Swift's `.rounded()` said and what the client's rail
    /// prints.
    #[test]
    fn an_extent_is_rounded_rather_than_truncated() {
        assert_eq!(points(1279.5), 1280);
        assert_eq!(points(1279.4), 1279);
        assert_eq!(points(-0.5), -1);
        assert_eq!(points(f64::NAN), 0);
        assert_eq!(points(f64::INFINITY), i32::MAX);
    }

    /// Only layer zero survives. A desktop is full of menus, tooltips and the Dock, and none of
    /// them is a window a person switches to.
    #[test]
    fn everything_above_the_app_window_layer_is_dropped_before_the_rules_see_it() {
        let source = WindowSource::new(
            Fixture {
                rows: vec![
                    row(1, 9, 0, true, VideoRect::xywh(0.0, 0.0, 400.0, 300.0)),
                    row(2, 9, 101, true, VideoRect::xywh(0.0, 0.0, 400.0, 300.0)),
                    row(3, 9, 24, true, VideoRect::xywh(0.0, 0.0, 400.0, 300.0)),
                ],
                frontmost: Some(9),
                displays: vec![VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0)],
                hidden: Vec::new(),
            },
            ListsEverything,
        );
        let windows = source.enumerate(0.0);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows.first().map(|window| window.window_id), Some(1));
    }

    /// The ordering contract: on-screen first, in census order, then the rest. The focused-window
    /// bit is read off the head of that list, so a shuffled one marks the wrong window.
    #[test]
    fn the_on_screen_block_comes_first_and_keeps_its_census_order() {
        let bounds = VideoRect::xywh(0.0, 0.0, 400.0, 300.0);
        let source = WindowSource::new(
            Fixture {
                rows: vec![
                    row(1, 9, 0, false, bounds),
                    row(2, 9, 0, true, bounds),
                    row(3, 9, 0, false, bounds),
                    row(4, 9, 0, true, bounds),
                ],
                frontmost: Some(9),
                displays: vec![VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0)],
                hidden: Vec::new(),
            },
            ListsEverything,
        );
        let ids: Vec<u32> = source
            .enumerate(0.0)
            .iter()
            .map(|window| window.window_id)
            .collect();
        assert_eq!(ids, vec![2, 4, 1, 3]);
    }

    /// The probe's verdict lands on the OFF-SCREEN block only, and an on-screen window is never
    /// marked minimized by it — the inclusion gate reads the two together, and a false minimized on
    /// a visible window would grey it in the client's rail.
    #[test]
    fn only_the_off_screen_block_carries_an_accessibility_verdict() {
        let bounds = VideoRect::xywh(0.0, 0.0, 400.0, 300.0);
        let source = WindowSource::new(
            Fixture {
                rows: vec![row(1, 9, 0, true, bounds), row(9, 9, 0, false, bounds)],
                frontmost: Some(9),
                displays: vec![VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0)],
                hidden: Vec::new(),
            },
            ListsEverything,
        );
        let windows = source.enumerate(0.0);
        let visible = windows.iter().find(|window| window.is_on_screen).cloned();
        let hidden = windows.iter().find(|window| !window.is_on_screen).cloned();
        assert_eq!(
            visible.map(|window| (window.is_minimized, window.is_ax_listed)),
            Some((false, false))
        );
        assert_eq!(
            hidden.map(|window| (window.is_minimized, window.is_ax_listed)),
            Some((true, true))
        );
    }

    /// The per-pid facts are read ONCE per app, not once per window. The cache is what keeps a
    /// forty-window app at two framework calls instead of eighty.
    #[test]
    fn the_two_per_application_facts_are_read_once_per_application() {
        let bounds = VideoRect::xywh(0.0, 0.0, 400.0, 300.0);
        let source = WindowSource::new(
            Fixture {
                rows: (1..=5).map(|id| row(id, 9, 0, true, bounds)).collect(),
                frontmost: Some(9),
                displays: vec![VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0)],
                hidden: vec![9],
            },
            ListsEverything,
        );
        let windows = source.enumerate(0.0);
        assert_eq!(windows.len(), 5);
        for window in &windows {
            assert_eq!(window.bundle_id, "com.example.p9");
            assert!(window.is_app_hidden);
            assert!(window.is_frontmost_app);
        }
    }

    /// The real desktop is not testable — every method needs a window server, TCC, or both — but it
    /// must never TRAP. This is the arm a headless suite reaches, and the one a locked screen
    /// takes.
    #[test]
    fn the_real_desktop_answers_rather_than_faulting() {
        let desktop = HostDesktop;
        let _ = desktop.frontmost_pid();
        drop(desktop.display_bounds());
        assert!(!desktop.is_hidden(i32::MAX));
        assert_eq!(desktop.bundle_id(i32::MAX), None);
        for window in desktop.census() {
            assert!(window.window_id > 0);
        }
    }
}
