//! Putting one window somewhere: park it on a display, put it back, un-minimize it, resize it.
//!
//! Four sequences of accessibility round-trips whose ORDER is load-bearing. Every DECISION inside
//! them is already written and golden-pinned — [`window_placement::place`] and
//! [`window_placement::fits`] are keys in `golden/golden_vectors.json`, [`match_window`] decides
//! which candidate is the window, [`display_for_window_frame`] decides which display a frame is on
//! — and this module adds none. What it owns is the order the effects go out in, and the roll-back
//! when one is refused.
//!
//! ## The order, in one place, because that is what the bug was
//! Park is size-BEFORE-position: an app asked to move across displays before it is asked to shrink
//! clamps the shrink against the display it is LEAVING. Restore is the inverse, origin-before-size,
//! for the inverse reason — crossing back to the roomier display before growing is what lets the
//! size take. Resize re-anchors at the display's top-left FIRST, because macOS clamps a size-set to
//! keep the window on screen from its CURRENT position. Deminiaturize is read-THEN-write, because
//! writing `false` to an already-false `AXMinimized` is an app-visible event on some apps and a
//! no-op on none.
//!
//! ## Why the framework is behind a trait
//! None of this can be tested against the real accessibility tree: it needs the grant, a window
//! server and a target app. The ORDER can be, and it is the only part that has ever been wrong, so
//! [`ResolvesWindows`] and [`ActsOnWindow`] are the seam and the sequences above them are covered
//! case by case.
//!
//! ## What it replaces, and the duplication it is honest about
//! `WindowPlacement.swift` and `WindowGeometryWatcher.resizeWindow`. Both were one-line faces over
//! `slopdesk_ffi::ax`'s doors, and that shim still holds the same four sequences — for the Swift
//! caller, which is still there. A Rust daemon cannot link `slopdesk-ffi` (it is the `no_mangle` C
//! shim, and it already depends on this direction), so the sequence is expressed natively here and
//! the shim's copy dies with the Swift, in the one commit that deletes `Sources/SlopDeskVideoHost`.

use core::fmt;

use slopdesk_video::ax_probe::{Candidate, Frame, match_window};
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::window_list::display_for_window_frame;
use slopdesk_video::window_placement;

/// The per-message accessibility cap every sequence here opens its application element with.
///
/// A quarter second — the same cap `slopdesk-ffi`'s `ax` module used, and the same the probe uses.
/// None of these is under a click, so none needs the tighter raise budget.
pub const TIMEOUT: f32 = 0.25;

/// The frame to pass when there is no fallback to offer, and it is NaN rather than zero on purpose.
///
/// Every comparison against a NaN is false, so a fallback match against this can never succeed —
/// while a zero rect would match a genuinely empty window sitting at the global origin, which is
/// what a window being torn down looks like for a frame or two.
pub const NO_FALLBACK: VideoRect = VideoRect::xywh(f64::NAN, f64::NAN, f64::NAN, f64::NAN);

/// What a park achieved, and where the window was before it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Parked {
    /// The window's pre-move global frame, for putting it back later.
    pub original: VideoRect,
    /// The width the window ACTUALLY took, which is not necessarily the width it was asked for.
    pub achieved_width: f64,
    /// The achieved height, on the same terms.
    pub achieved_height: f64,
}

/// What an un-minimize did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Deminiaturized {
    /// The window was not found, or the write was refused.
    Failed,
    /// The window was not minimized, so nothing was written.
    NotMinimized,
    /// The window was minimized and has been asked to come back.
    Restoring,
}

/// The two reads and three writes one accessibility window answers.
///
/// Deliberately NOT "a window": nothing here says which window it is or whether it is the right
/// one. That question is [`ResolvesWindows`]'s, and the answer to it is what a caller holds.
pub trait ActsOnWindow: fmt::Debug {
    /// The window's global frame in top-left points, or `None` when it cannot be read.
    fn frame(&self) -> Option<VideoRect>;
    /// Moves the window's top-left corner; answers whether the app accepted it.
    fn set_origin(&self, x: f64, y: f64) -> bool;
    /// Resizes the window; answers whether the app accepted it. An app may CLAMP a size it accepts,
    /// which is why every caller reads the frame back rather than trusting a `true`.
    fn set_size(&self, width: f64, height: f64) -> bool;
    /// Whether the window is minimized into the Dock, or `None` when it cannot be read.
    fn minimized(&self) -> Option<bool>;
    /// Minimizes or un-minimizes; answers whether the app accepted it.
    fn set_minimized(&self, minimized: bool) -> bool;
}

/// Finding one window of one process in the accessibility tree.
pub trait ResolvesWindows: Send + Sync + fmt::Debug {
    /// What a resolved window is.
    type Window: ActsOnWindow;
    /// The window `window_id` of `pid`, or `None`.
    ///
    /// `fallback` is the frame to match against when the private id symbol answers for NO candidate
    /// at all, which is what a locked screen does. [`NO_FALLBACK`] refuses the fallback outright.
    fn resolve(&self, pid: i32, window_id: u32, fallback: VideoRect, timeout: f32) -> Option<Self::Window>;
}

/// The real accessibility tree.
#[derive(Clone, Copy, Debug, Default)]
pub struct AccessibilityTree;

impl ActsOnWindow for slopdesk_apple_ax::Window {
    fn frame(&self) -> Option<VideoRect> {
        Self::frame(self).map(|frame| VideoRect::xywh(frame.x, frame.y, frame.width, frame.height))
    }
    fn set_origin(&self, x: f64, y: f64) -> bool {
        Self::set_origin(self, x, y)
    }
    fn set_size(&self, width: f64, height: f64) -> bool {
        Self::set_size(self, width, height)
    }
    fn minimized(&self) -> Option<bool> {
        Self::minimized(self)
    }
    fn set_minimized(&self, minimized: bool) -> bool {
        Self::set_minimized(self, minimized)
    }
}

impl ResolvesWindows for AccessibilityTree {
    type Window = slopdesk_apple_ax::Window;

    /// The preamble every sequence here opens with: make an application element, cap its messaging
    /// timeout, list its windows, ask each for its `CGWindowID`, and let
    /// [`slopdesk_video::ax_probe::match_window`] pick.
    ///
    /// The app element is dropped when this returns and the window is not, which is fine: an
    /// `AXUIElement` for a window is independent of the one for its application, and the messaging
    /// cap was stamped on the window when it was read out of `AXWindows`.
    fn resolve(&self, pid: i32, window_id: u32, fallback: VideoRect, timeout: f32) -> Option<Self::Window> {
        let app = slopdesk_apple_ax::App::new(pid, timeout);
        let mut windows = app.windows();
        let candidates: Vec<Candidate> = windows
            .iter()
            .map(|window| {
                Candidate {
                    id: window.id(),
                    frame: window.frame().map(|frame| {
                        Frame {
                            x: frame.x,
                            y: frame.y,
                            width: frame.width,
                            height: frame.height,
                        }
                    }),
                }
            })
            .collect();
        let wanted = Frame {
            x: fallback.origin.x,
            y: fallback.origin.y,
            width: fallback.size.width,
            height: fallback.size.height,
        };
        let index = match_window(&candidates, window_id, wanted)?;
        if index >= windows.len() {
            return None;
        }
        Some(windows.swap_remove(index))
    }
}

/// Puts `window` back at `frame`: ORIGIN first, then size.
///
/// The inverse order of a park, and for the inverse reason — crossing back to the roomier display
/// before growing is what lets the size take at all.
fn put_back<W: ActsOnWindow>(window: &W, frame: VideoRect) {
    let _ = window.set_origin(frame.origin.x, frame.origin.y);
    let _ = window.set_size(frame.size.width, frame.size.height);
}

/// Moves the window fully onto `display`, shrinking it first if it does not fit.
///
/// `None` — touching nothing further — on every failure: the window is not found, its pre-move
/// frame is unreadable, the position write is refused, or the app clamped the shrink so the window
/// still overhangs. On the last two the window is rolled BACK to where it started, so the caller's
/// 1× fallback captures it cleanly in place rather than over-cropping a half-moved one.
pub fn park<T: ResolvesWindows>(tree: &T, window_id: u32, pid: i32, display: VideoRect) -> Option<Parked> {
    if pid <= 0 {
        return None;
    }
    let window = tree.resolve(pid, window_id, NO_FALLBACK, TIMEOUT)?;
    let original = window.frame()?;
    let plan = window_placement::place(
        original.size.width,
        original.size.height,
        display.origin.x,
        display.origin.y,
        display.size.width,
        display.size.height,
    );
    if plan.needs_resize {
        let _ = window.set_size(plan.width, plan.height);
    }
    if !window.set_origin(plan.origin_x, plan.origin_y) {
        put_back(&window, original);
        return None;
    }
    let achieved = window.frame().map_or((plan.width, plan.height), |frame| {
        (frame.size.width, frame.size.height)
    });
    if !window_placement::fits(achieved.0, achieved.1, display.size.width, display.size.height) {
        put_back(&window, original);
        return None;
    }
    Some(Parked {
        original,
        achieved_width: achieved.0,
        achieved_height: achieved.1,
    })
}

/// Puts the window back at `frame` — the inverse of a park, origin before size.
///
/// Answers whether the window was found at all. The two writes are best-effort past that: an app
/// that refuses one of them leaves the window where it refused, and there is nothing better to do.
pub fn restore<T: ResolvesWindows>(tree: &T, window_id: u32, pid: i32, frame: VideoRect) -> bool {
    if pid <= 0 {
        return false;
    }
    let Some(window) = tree.resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return false;
    };
    put_back(&window, frame);
    true
}

/// Un-minimizes the window so the window server paints it again.
///
/// A minimized window is never rendered, so capturing one streams nothing. Read-THEN-write: a
/// window that is not minimized is left completely untouched.
pub fn deminiaturize<T: ResolvesWindows>(tree: &T, window_id: u32, pid: i32) -> Deminiaturized {
    if pid <= 0 {
        return Deminiaturized::Failed;
    }
    let Some(window) = tree.resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return Deminiaturized::Failed;
    };
    if window.minimized() != Some(true) {
        return Deminiaturized::NotMinimized;
    }
    if window.set_minimized(false) {
        Deminiaturized::Restoring
    } else {
        Deminiaturized::Failed
    }
}

/// Resizes the window and answers the size it ACTUALLY took.
///
/// `displays` is every display's bounds, used for one thing: re-anchoring the window at its
/// display's top-left corner BEFORE the size write. macOS clamps an accessibility size-set to keep
/// the window on screen from its CURRENT position, so a window parked mid-screen cannot grow to
/// fill the display until it has been moved to the origin first. Lending nothing skips the
/// re-anchor, which is right for a caller that already knows the window is at an origin.
///
/// `None` when the window is not found or refuses the size write — a fixed-size window and a hung
/// app both land here, and both mean the caller keeps its old encoder and sends no acknowledgement.
pub fn resize<T: ResolvesWindows>(
    tree: &T,
    window_id: u32,
    pid: i32,
    width: f64,
    height: f64,
    displays: &[VideoRect],
) -> Option<(f64, f64)> {
    if pid <= 0 {
        return None;
    }
    let window = tree.resolve(pid, window_id, NO_FALLBACK, TIMEOUT)?;
    if let Some(live) = window.frame()
        && let Some(display) = display_for_window_frame(live, displays)
    {
        // Best-effort: a window that refuses the position write still gets the size write below.
        let _ = window.set_origin(display.origin.x, display.origin.y);
    }
    if !window.set_size(width.max(1.0), height.max(1.0)) {
        return None;
    }
    Some(
        window
            .frame()
            .map_or((width, height), |frame| (frame.size.width, frame.size.height)),
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, PoisonError};

    use slopdesk_video::geometry::VideoRect;

    use super::{ActsOnWindow, Deminiaturized, ResolvesWindows, deminiaturize, park, resize, restore};

    /// Every effect a sequence sent, in order.
    #[derive(Clone, Copy, Debug, PartialEq)]
    enum Effect {
        Origin(f64, f64),
        Size(f64, f64),
        Minimized(bool),
    }

    /// A window that records what it was told and answers a frame that follows the writes.
    #[expect(
        clippy::struct_excessive_bools,
        reason = "each flag is one app refusal the sequences must survive; an enum per pair would name \
                  nothing the field name does not"
    )]
    #[derive(Debug)]
    struct Recorded {
        frame: Mutex<Option<VideoRect>>,
        log: Mutex<Vec<Effect>>,
        accepts_origin: bool,
        accepts_size: bool,
        /// A size the app CLAMPS to whatever it is asked for — an oversized window that refuses to
        /// shrink is the case the roll-back exists for.
        clamps_size: bool,
        minimized: Mutex<Option<bool>>,
        accepts_minimize: bool,
    }

    impl Default for Recorded {
        fn default() -> Self {
            Self {
                frame: Mutex::new(Some(VideoRect::xywh(500.0, 400.0, 1600.0, 1200.0))),
                log: Mutex::new(Vec::new()),
                accepts_origin: true,
                accepts_size: true,
                clamps_size: false,
                minimized: Mutex::new(Some(false)),
                accepts_minimize: true,
            }
        }
    }

    impl Recorded {
        fn effects(&self) -> Vec<Effect> {
            self.log.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl ActsOnWindow for &Recorded {
        fn frame(&self) -> Option<VideoRect> {
            *self.frame.lock().unwrap_or_else(PoisonError::into_inner)
        }
        fn set_origin(&self, x: f64, y: f64) -> bool {
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Effect::Origin(x, y));
            if !self.accepts_origin {
                return false;
            }
            {
                let mut frame = self.frame.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(live) = frame.as_mut() {
                    live.origin.x = x;
                    live.origin.y = y;
                }
            }
            true
        }
        fn set_size(&self, width: f64, height: f64) -> bool {
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Effect::Size(width, height));
            if !self.accepts_size {
                return false;
            }
            if self.clamps_size {
                // Accepted, and ignored — which is exactly what an app with a minimum size does.
                return true;
            }
            {
                let mut frame = self.frame.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(live) = frame.as_mut() {
                    live.size.width = width;
                    live.size.height = height;
                }
            }
            true
        }
        fn minimized(&self) -> Option<bool> {
            *self.minimized.lock().unwrap_or_else(PoisonError::into_inner)
        }
        fn set_minimized(&self, minimized: bool) -> bool {
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Effect::Minimized(minimized));
            if !self.accepts_minimize {
                return false;
            }
            *self.minimized.lock().unwrap_or_else(PoisonError::into_inner) = Some(minimized);
            true
        }
    }

    /// A tree holding exactly one window, or none.
    #[derive(Debug)]
    struct Tree<'a>(Option<&'a Recorded>);

    impl<'a> ResolvesWindows for Tree<'a> {
        type Window = &'a Recorded;
        fn resolve(
            &self,
            _pid: i32,
            _window_id: u32,
            _fallback: VideoRect,
            _timeout: f32,
        ) -> Option<&'a Recorded> {
            self.0
        }
    }

    const DISPLAY: VideoRect = VideoRect::xywh(0.0, 0.0, 1280.0, 800.0);

    /// THE order. A window too big for the display is SHRUNK before it is MOVED, because an app
    /// asked to move first clamps the shrink against the display it is leaving. This is the one
    /// thing in this module that has ever been wrong.
    #[test]
    fn a_park_shrinks_before_it_moves() {
        let window = Recorded::default();
        let parked = park(&Tree(Some(&window)), 1, 9, DISPLAY);
        assert_eq!(window.effects(), vec![
            Effect::Size(1280.0, 800.0),
            Effect::Origin(0.0, 0.0)
        ]);
        assert_eq!(
            parked.map(|parked| (parked.original, parked.achieved_width, parked.achieved_height)),
            Some((VideoRect::xywh(500.0, 400.0, 1600.0, 1200.0), 1280.0, 800.0))
        );
    }

    /// A window that already fits is MOVED and never resized — the plan says so, and a size write
    /// an app did not need is one more chance for it to do something surprising.
    #[test]
    fn a_park_of_a_window_that_already_fits_writes_no_size_at_all() {
        let window = Recorded {
            frame: Mutex::new(Some(VideoRect::xywh(500.0, 400.0, 400.0, 300.0))),
            ..Recorded::default()
        };
        assert!(park(&Tree(Some(&window)), 1, 9, DISPLAY).is_some());
        assert_eq!(window.effects(), vec![Effect::Origin(0.0, 0.0)]);
    }

    /// An app that ACCEPTS the shrink and then ignores it leaves the window overhanging, and the
    /// park must answer `None` — a successful 2× move whose window does not fit would over-crop the
    /// capture and desync the client's input mapping. The window goes back where it started.
    #[test]
    fn a_park_the_app_clamped_rolls_the_window_all_the_way_back() {
        let window = Recorded {
            clamps_size: true,
            ..Recorded::default()
        };
        assert_eq!(park(&Tree(Some(&window)), 1, 9, DISPLAY), None);
        assert_eq!(window.effects(), vec![
            Effect::Size(1280.0, 800.0),
            Effect::Origin(0.0, 0.0),
            // The roll-back, origin before size.
            Effect::Origin(500.0, 400.0),
            Effect::Size(1600.0, 1200.0),
        ]);
    }

    /// A refused POSITION write rolls back too, and does it before reading anything else — the
    /// window is half-moved at that point and the caller's fallback needs it whole.
    #[test]
    fn a_park_whose_move_is_refused_rolls_back_immediately() {
        let window = Recorded {
            accepts_origin: false,
            ..Recorded::default()
        };
        assert_eq!(park(&Tree(Some(&window)), 1, 9, DISPLAY), None);
        assert_eq!(window.effects(), vec![
            Effect::Size(1280.0, 800.0),
            Effect::Origin(0.0, 0.0),
            Effect::Origin(500.0, 400.0),
            Effect::Size(1600.0, 1200.0),
        ]);
    }

    /// A window the tree cannot resolve, and a pid that is not a process, both answer `None`
    /// without touching anything.
    #[test]
    fn a_park_with_nothing_to_park_touches_nothing() {
        assert_eq!(park(&Tree(None), 1, 9, DISPLAY), None);
        let window = Recorded::default();
        assert_eq!(park(&Tree(Some(&window)), 1, 0, DISPLAY), None);
        assert_eq!(park(&Tree(Some(&window)), 1, -1, DISPLAY), None);
        assert!(window.effects().is_empty());
    }

    /// The restore's order is the park's inverse: ORIGIN first, then size. Growing before crossing
    /// back would be clamped against the small display the window is still on.
    #[test]
    fn a_restore_moves_before_it_grows() {
        let window = Recorded::default();
        assert!(restore(
            &Tree(Some(&window)),
            1,
            9,
            VideoRect::xywh(120.0, 60.0, 900.0, 700.0)
        ));
        assert_eq!(window.effects(), vec![
            Effect::Origin(120.0, 60.0),
            Effect::Size(900.0, 700.0)
        ]);
    }

    /// Read-THEN-write: a window that is not minimized is left completely untouched. Writing
    /// `false` to an already-false `AXMinimized` is an app-visible event on some apps and a
    /// no-op on none.
    #[test]
    fn an_un_minimize_of_a_window_that_is_not_minimized_writes_nothing() {
        let window = Recorded::default();
        assert_eq!(
            deminiaturize(&Tree(Some(&window)), 1, 9),
            Deminiaturized::NotMinimized
        );
        assert!(window.effects().is_empty());
    }

    /// A minimized window is asked to come back, and the three outcomes are distinct — the
    /// mint-time rescue treats "not minimized" as success and "failed" as a reason to give up.
    #[test]
    fn an_un_minimize_reports_which_of_the_three_things_happened() {
        let minimized = Recorded {
            minimized: Mutex::new(Some(true)),
            ..Recorded::default()
        };
        assert_eq!(
            deminiaturize(&Tree(Some(&minimized)), 1, 9),
            Deminiaturized::Restoring
        );
        assert_eq!(minimized.effects(), vec![Effect::Minimized(false)]);

        let refusing = Recorded {
            minimized: Mutex::new(Some(true)),
            accepts_minimize: false,
            ..Recorded::default()
        };
        assert_eq!(
            deminiaturize(&Tree(Some(&refusing)), 1, 9),
            Deminiaturized::Failed
        );
        assert_eq!(deminiaturize(&Tree(None), 1, 9), Deminiaturized::Failed);
    }

    /// The re-anchor: a window sitting mid-display is moved to that display's ORIGIN before the
    /// size write, or macOS clamps the growth to keep it on screen from where it is.
    #[test]
    fn a_resize_re_anchors_at_the_display_origin_first() {
        let window = Recorded {
            frame: Mutex::new(Some(VideoRect::xywh(300.0, 200.0, 400.0, 300.0))),
            ..Recorded::default()
        };
        let achieved = resize(&Tree(Some(&window)), 1, 9, 1280.0, 800.0, &[DISPLAY]);
        assert_eq!(achieved, Some((1280.0, 800.0)));
        assert_eq!(window.effects(), vec![
            Effect::Origin(0.0, 0.0),
            Effect::Size(1280.0, 800.0)
        ]);
    }

    /// Lending NO displays skips the re-anchor, which is the right call for a caller that already
    /// knows where the window is.
    #[test]
    fn a_resize_with_no_displays_lent_writes_only_the_size() {
        let window = Recorded {
            frame: Mutex::new(Some(VideoRect::xywh(300.0, 200.0, 400.0, 300.0))),
            ..Recorded::default()
        };
        assert!(resize(&Tree(Some(&window)), 1, 9, 640.0, 480.0, &[]).is_some());
        assert_eq!(window.effects(), vec![Effect::Size(640.0, 480.0)]);
    }

    /// A size of zero or less is floored at one point before it goes out: an accessibility size-set
    /// of zero is a window some apps never come back from.
    #[test]
    fn a_resize_never_asks_for_less_than_one_point() {
        let window = Recorded::default();
        assert!(resize(&Tree(Some(&window)), 1, 9, 0.0, -50.0, &[]).is_some());
        assert_eq!(window.effects(), vec![Effect::Size(1.0, 1.0)]);
    }

    /// The ACHIEVED size is what is answered, never the requested one. An app that clamps has to be
    /// the source of truth, because the encoder and the `resizeAck` are configured from it.
    #[test]
    fn a_resize_answers_what_the_window_took_and_not_what_it_was_asked_for() {
        let window = Recorded {
            frame: Mutex::new(Some(VideoRect::xywh(0.0, 0.0, 700.0, 500.0))),
            clamps_size: true,
            ..Recorded::default()
        };
        assert_eq!(
            resize(&Tree(Some(&window)), 1, 9, 1280.0, 800.0, &[]),
            Some((700.0, 500.0))
        );
    }

    /// A window that refuses the size write aborts the whole resize — the caller keeps its old
    /// encoder and sends no acknowledgement, which is what a fixed-size window and a hung app both
    /// need to look like.
    #[test]
    fn a_resize_a_window_refuses_is_aborted_rather_than_reported() {
        let window = Recorded {
            accepts_size: false,
            ..Recorded::default()
        };
        assert_eq!(resize(&Tree(Some(&window)), 1, 9, 640.0, 480.0, &[]), None);
        assert_eq!(resize(&Tree(None), 1, 9, 640.0, 480.0, &[]), None);
        assert_eq!(resize(&Tree(Some(&window)), 1, 0, 640.0, 480.0, &[]), None);
    }
}
