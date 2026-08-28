//! The `HiDPI` virtual display's LIFETIME: bring it up, notice `WindowServer` tore it down, bring
//! it back, and answer the one-shot that asks whether `ScreenCaptureKit` can even see it.
//!
//! Replaces the Swift host's virtual display (the handle and its trampoline), the recovery policy
//! beside it (the termination and re-create policies) and the `runVDSCKProbe()` half of the Swift
//! daemon's `main`.
//!
//! ## What is here, and what emphatically is not
//! Effects and one lock. Every NUMBER this module hands to the framework is asked for:
//! [`slopdesk_video::virtual_display`] owns the point grid, the backing pixels, the millimetre
//! size, the advertised refresh rates and where the display lands in the global space, and
//! [`slopdesk_video::capture_recovery`] owns the cooldown, the single-flight rule and the set
//! arithmetic that says which channels a termination costs. Both are `forbid(unsafe_code)`, both
//! are pinned by `golden/golden_vectors.json` (`virtualDisplayGeometry`, `vdOriginToRight`,
//! `vdChipPixelLimit`, `vdRefreshRates`), and NOTHING here recomputes one of them. What is left
//! over — a `CGVirtualDisplay` that must be created off the main thread, a gate that two mints can
//! reach at once, a 400 ms settle — is what a daemon is for.
//!
//! ## The two threading rules, which point in opposite directions
//! [`slopdesk_apple_cgvirtualdisplay::VirtualDisplay::create`] BLOCKS for up to about eleven
//! seconds and hops to the main thread twice INSIDE itself, so calling it FROM the main thread
//! deadlocks. Every entry point here that can reach it — [`bring_up`] and [`ensure_live`] — carries
//! that warning, because the caller is the only one that knows which thread it is on. The Swift
//! spelled this as `Task.detached`; a Rust daemon spells it as "not the thread that services the
//! run loop", and `main.rs` keeps that thread free for exactly this reason.
//!
//! ## Why the gate holds the LOCK and not the rule
//! [`slopdesk_video::capture_recovery::VirtualDisplayRecreateGate`] is a `Copy` value with
//! `begin`/`end` and no interior mutability, and its own doc says why: the caller owns whatever
//! lock its lanes need rather than the gate hiding one. Here that caller is [`Recreate`], and the
//! lock is a plain `Mutex` rather than an atomic pair because `begin` reads the cooldown stamp and
//! the in-flight flag and writes both — two mints racing a dead display must not both come out
//! holding the flight. The lock is NEVER held across [`VirtualDisplay::create`]: `begin` closes it,
//! the multi-second blocking call runs unlocked, and `end` re-takes it. A gate held across the call
//! would serialise every other pane's mint behind one `WindowServer` stall, which is the failure
//! the single-flight exists to avoid.
//!
//! ## What is untestable by design
//! [`bring_up`], [`ensure_live`] and [`run_sck_probe`] all reach `WindowServer` and,
//! for the probe, a Screen-Recording TCC grant. ⚠️ They cannot run under a test. The parts that
//! can — the geometry the chip limit produces, the gate's ladder, and the disconnect set — are the
//! parts the `#[cfg(test)] mod tests` below covers, and they are the parts that could be wrong.

use std::collections::BTreeSet;
use std::sync::{Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use slopdesk_apple_cgvirtualdisplay::{VirtualDisplay, private_classes_available};
use slopdesk_apple_sck::ShareableContent;
use slopdesk_video::capture_recovery;
use slopdesk_video::virtual_display::{Geometry, chip_pixel_limit};

/// The backing scale the daemon's display is always created at.
///
/// The whole point of the virtual display is a 2× render the encoder can downscale from — a
/// supersampled 1× capture is sharper than a native 1× one, which is the trade
/// `SLOPDESK_CAPTURE_SCALE` exposes. A 1× virtual display would buy nothing over the window's own
/// screen.
pub const SCALE: i32 = 2;

/// The name `WindowServer` and every display list will show for the daemon's display.
///
/// A constant rather than a parameter because it is user-visible in System Settings: two spellings
/// would mean two entries after an unclean exit, and there would be no way to tell which is stale.
pub const NAME: &str = "SlopDesk Remote";

/// The `--vd-sck-probe` display's point width.
pub const PROBE_POINT_WIDTH: i32 = 1920;

/// The `--vd-sck-probe` display's point height.
pub const PROBE_POINT_HEIGHT: i32 = 1080;

/// The `--vd-sck-probe` display's backing scale.
///
/// 1×, unlike [`SCALE`]: the probe asks whether `ScreenCaptureKit` ENUMERATES a virtual display at
/// all, and a `HiDPI` one would add a second variable to a one-bit answer.
pub const PROBE_SCALE: i32 = 1;

/// The `--vd-sck-probe` display's advertised frame rate.
pub const PROBE_FPS: i32 = 60;

/// The name the probe's display carries, distinct from [`NAME`] so a probe left behind by a crash
/// is identifiable in System Settings.
pub const PROBE_NAME: &str = "SlopDesk SCK Probe";

/// How long the probe waits after the display comes online before asking `ScreenCaptureKit`.
///
/// `ScreenCaptureKit`'s view of the display list is out of process and lags `WindowServer`'s by
/// enough that an immediate query answers "not there" for a display that is. This is the Swift's
/// own 400 ms, kept because it is the number the verdict was calibrated against — shortening it
/// would turn a timing artefact into a `❌`.
pub const PROBE_SETTLE: Duration = Duration::from_millis(400);

/// Whether the four private `CoreGraphics` classes resolve on this OS.
///
/// `false` means every entry point here answers "no display" rather than crashing: a future macOS
/// that renames one of them costs the daemon its sharpness, not its life.
#[must_use]
pub fn available() -> bool {
    private_classes_available()
}

/// The geometry a daemon display of `point_width` × `point_height` takes on this machine.
///
/// `cpu_brand` is `machdep.cpu.brand_string`, and an EMPTY string is a legitimate argument: it is
/// what the sysctl answers when it fails, and [`chip_pixel_limit`] maps it to the permissive limit
/// on purpose, so a machine whose chip cannot be identified is refused nothing up front and finds
/// out from `WindowServer` instead. Passing the brand in rather than reading it here is what keeps
/// this function testable and what keeps the one sysctl in the daemon's order.
///
/// The chip limit is consulted BEFORE the display is created rather than after: an oversized
/// framebuffer on a base M-series part fails inside `applySettings:`, which is a multi-second stall
/// before the refusal. [`Geometry::exceeds_pixel_limit`] turns that into an immediate `None`.
#[must_use]
pub fn geometry(point_width: i32, point_height: i32, cpu_brand: &str) -> Geometry {
    Geometry::new(point_width, point_height, SCALE, chip_pixel_limit(cpu_brand))
}

/// A live virtual display, as a mint needs to see it.
///
/// The scale is read from the display rather than from [`SCALE`] because the display is the single
/// source of truth: a `WindowServer` that granted a different backing ratio than it was asked for
/// would otherwise make every capture off by that ratio, silently.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Live {
    /// The `CGDirectDisplayID` a capture filter and a window park both key on.
    pub display_id: u32,
    /// The display's REAL backing scale, never below 1.
    pub scale: u32,
}

/// What [`ensure_live`] found, and what the caller should say about it.
///
/// Four answers rather than an `Option` because three of them mean "capture at 1× this time" for
/// three different reasons, and the daemon logs a different line for each: a throttled retry is
/// normal, a failed re-create is worth noticing, and no display at all is the configured state when
/// `SLOPDESK_VD=0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Availability {
    /// The display was already up. The common case, and the one that takes no lock beyond the read.
    Live(Live),
    /// The display was dead, this caller won the flight, and the re-create landed.
    Recreated(Live),
    /// The display was dead, this caller won the flight, and `WindowServer` refused. The cooldown
    /// is already stamped, so the next mint inside it does not try again.
    RecreateFailed,
    /// The display is dead and this caller is not the one retrying — another mint holds the flight,
    /// or the cooldown has not elapsed. Capture 1× and let a later hello retry.
    Throttled,
}

/// Everything a re-create needs, minus the display handle itself.
///
/// The handle is deliberately NOT held here. `main.rs` owns it for the daemon's lifetime and hands
/// it to [`ensure_live`] per call, which is what lets this type be constructed and driven in a test
/// with no window server — the gate ladder is the half that can be wrong.
#[derive(Debug)]
pub struct Recreate {
    geometry: Geometry,
    fps: i32,
    gate: Mutex<capture_recovery::VirtualDisplayRecreateGate>,
}

impl Recreate {
    /// Arms the lazy re-create for a display of `geometry` advertising `fps`.
    ///
    /// The cooldown is [`capture_recovery::RECREATE_COOLDOWN_SECONDS`] and is not a parameter: a
    /// per-daemon cooldown would be a knob whose only correct value is the one the rule already
    /// holds.
    #[must_use]
    pub const fn new(geometry: Geometry, fps: i32) -> Self {
        Self {
            geometry,
            fps,
            gate: Mutex::new(capture_recovery::VirtualDisplayRecreateGate::new(
                capture_recovery::RECREATE_COOLDOWN_SECONDS,
            )),
        }
    }

    /// The geometry a re-created display will take — the SAME one the first bring-up used.
    ///
    /// Recomputing it from the chip limit at re-create time would let a display come back a
    /// different size than the panes parked on it were sized against.
    #[must_use]
    pub const fn geometry(&self) -> Geometry {
        self.geometry
    }

    /// The frame rate the re-created display advertises.
    #[must_use]
    pub const fn fps(&self) -> i32 {
        self.fps
    }

    /// Claims the single flight if the cooldown has elapsed and no one else holds it.
    ///
    /// `now` is any monotonic clock in SECONDS, as long as it is the same one every caller uses —
    /// the Swift passed `ProcessInfo.processInfo.systemUptime`. The stamp is taken at BEGIN, not at
    /// end, so a re-create that blocks for eleven seconds does not extend the cooldown by eleven
    /// seconds.
    ///
    /// Every `true` MUST be paired with [`Self::end`], or the flight is held forever and the
    /// display never comes back.
    pub fn begin(&self, now: f64) -> bool {
        self.gate
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .begin(now)
    }

    /// Releases the single flight. Idempotent, and safe to call after a failed attempt — the
    /// cooldown stamp survives it, which is what makes a failure throttle the next mint.
    pub fn end(&self) {
        self.gate.lock().unwrap_or_else(PoisonError::into_inner).end();
    }
}

/// Reads the display's identifier and scale, or `None` when there is no live display.
///
/// Both reads are atomics on the handle, answerable WHILE another pane's blocking `create` is still
/// inside `WindowServer`. That is exactly what the mint path wants: a hello that arrives mid-create
/// degrades to 1× instead of queueing behind eleven seconds of Mach round-trip.
#[must_use]
pub fn live(display: &VirtualDisplay) -> Option<Live> {
    let display_id = display.display_id();
    (display_id != 0).then(|| {
        Live {
            display_id,
            scale: display.scale().max(1),
        }
    })
}

/// Creates the daemon's display, under [`NAME`], and answers its identifier.
///
/// ⚠️ BLOCKS for as long as `WindowServer` takes — up to the apply ceiling plus about 1.2 seconds
/// of polling and settling. ⚠️ MUST NOT be called from the main thread: it hops to main twice
/// inside itself and would deadlock on the queue it is already on.
///
/// `None` means the daemon captures 1× in place: the private classes are gone, the geometry
/// exceeds the chip's framebuffer limit, or `WindowServer` refused. All three are the same answer
/// to the caller and none of them is fatal.
#[must_use]
pub fn bring_up(display: &VirtualDisplay, geometry: &Geometry, fps: i32) -> Option<u32> {
    display.create(geometry, NAME, fps)
}

/// The mint path's view of the display: live, or re-created on the spot if this caller wins.
///
/// This is `resolvePaneCapture`'s recovery half. The display is RE-QUERIED per mint rather than
/// captured once at launch, because `WindowServer` can tear it down at any time — sleep/wake, a GPU
/// reset, a fast user switch — and the termination handler clears the identifier, so a stale copy
/// would park a window onto a display that no longer exists.
///
/// ⚠️ On the [`Availability::Recreated`] and [`Availability::RecreateFailed`] arms this BLOCKS
/// inside [`bring_up`] for seconds, and inherits its no-main-thread rule. The gate's lock is closed
/// before the call and re-opened after, so sibling mints answer [`Availability::Throttled`]
/// immediately instead of waiting.
#[must_use]
pub fn ensure_live(display: &VirtualDisplay, recreate: &Recreate, now: f64) -> Availability {
    if let Some(found) = live(display) {
        return Availability::Live(found);
    }
    if !recreate.begin(now) {
        return Availability::Throttled;
    }
    let created = bring_up(display, &recreate.geometry(), recreate.fps());
    recreate.end();
    // Re-read rather than trust the returned identifier: the handle is what every later mint reads,
    // and a create that landed but whose publication has not settled must not be reported live.
    created
        .and_then(|_| live(display))
        .map_or(Availability::RecreateFailed, Availability::Recreated)
}

/// Which channels a virtual-display termination costs, in ascending order.
///
/// The rule is [`capture_recovery::channels_to_disconnect`]'s — the intersection of what is parked
/// with what is live — and the only thing added here is the shape: the daemon holds its channels in
/// whatever collection its lanes wanted, and the rule wants two ordered sets. The intersection is
/// the point: a channel parked onto the dead display cannot be recovered in place, and a channel
/// that is live but never parked has nothing to recover from.
pub fn channels_to_disconnect(
    parked: impl IntoIterator<Item = u32>,
    live_channels: impl IntoIterator<Item = u32>,
) -> Vec<u32> {
    let parked: BTreeSet<u32> = parked.into_iter().collect();
    let live_channels: BTreeSet<u32> = live_channels.into_iter().collect();
    capture_recovery::channels_to_disconnect(&parked, &live_channels)
}

/// What `--vd-sck-probe` concluded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeVerdict {
    /// `ScreenCaptureKit` listed the probe's display. The desktop mint can target it.
    Enumerated,
    /// The display exists but `ScreenCaptureKit` does not list it. The desktop mint needs another
    /// path.
    Missing,
    /// No display was created — no `WindowServer`, or the OS refused the descriptor.
    NoDisplay,
    /// `ScreenCaptureKit` answered nothing at all, which is what a missing Screen-Recording grant
    /// looks like from here. Distinct from [`Self::Missing`]: one is a verdict, the other is a
    /// broken instrument.
    NoContent,
}

/// The probe's verdict, and the lines the daemon should print for it.
///
/// Lines rather than prints: `print_stdout` and `print_stderr` are denied in this crate, and the
/// one place a byte reaches a terminal is `main.rs`'s `say`. That is not a lint workaround — it is
/// what makes the probe a function with a return value rather than a side effect, and therefore
/// what lets the verdict be checked by something other than a human reading a log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProbeReport {
    /// What the probe concluded.
    pub verdict: ProbeVerdict,
    /// One line per thing worth saying, in the order it was learned.
    pub lines: Vec<String>,
}

/// Runs the `--vd-sck-probe` one-shot: create a display, wait for it to settle, ask
/// `ScreenCaptureKit` whether it can see it, then take it down again.
///
/// ⚠️ Requires a window server and a Screen-Recording grant, and ⚠️ MUST NOT run on the main
/// thread — [`bring_up`] hops to main inside itself. The caller runs this on a worker while the
/// main thread services its run loop, which is the shape the Swift's `Task` plus `dispatchMain()`
/// had.
///
/// The display is torn down before returning, on EVERY arm including the failures. A probe that
/// leaves a registered `CGVirtualDisplay` behind changes the arrangement of the machine it was
/// meant to only observe.
///
/// One thing the Swift printed is missing here, deliberately rather than by omission:
/// `SCShareableContent.displays` has no accessor in `slopdesk-apple-sck`, and neither does
/// `CGMainDisplayID()` in `slopdesk-apple-cgdisplay`. The verdict does not need either — it is
/// `content.display(id).is_some()` — so the listing is rebuilt from `CoreGraphics`' own online list
/// with each entry asked of `ScreenCaptureKit` individually. That answers strictly more than the
/// Swift did: it names which displays the two views disagree about, not just how many each has.
#[must_use]
pub fn run_sck_probe() -> ProbeReport {
    let mut lines = Vec::new();
    let display = VirtualDisplay::new();
    let geometry = Geometry::new(
        PROBE_POINT_WIDTH,
        PROBE_POINT_HEIGHT,
        PROBE_SCALE,
        // The permissive limit, asked for rather than spelled: the probe is 1920×1080 at 1×, which
        // no chip refuses, and hard-coding a number here would be a second spelling of the ladder.
        chip_pixel_limit(""),
    );
    let Some(vd_id) = display.create(&geometry, PROBE_NAME, PROBE_FPS) else {
        lines.push("vd-sck-probe: FAIL — VD create returned nil (no WindowServer / OS refused)".to_owned());
        return ProbeReport {
            verdict: ProbeVerdict::NoDisplay,
            lines,
        };
    };
    lines.push(format!(
        "vd-sck-probe: VD online id={vd_id}; enumerating displays through ScreenCaptureKit…"
    ));
    thread::sleep(PROBE_SETTLE);

    let report = match ShareableContent::current(false, true) {
        None => {
            lines.push("vd-sck-probe: SCShareableContent failed (Screen-Recording TCC missing?)".to_owned());
            ProbeVerdict::NoContent
        },
        Some(content) => {
            let online = slopdesk_apple_cgdisplay::online();
            lines.push(format!(
                "vd-sck-probe: CoreGraphics lists {} display(s); asking SCK about each:",
                online.len()
            ));
            for entry in &online {
                let seen = if content.display(entry.id).is_some() {
                    "SCK: yes"
                } else {
                    "SCK: NO"
                };
                let tag = if entry.id == vd_id { " ◀ THE VD" } else { "" };
                lines.push(format!(
                    "  displayID={} frame={:.0}x{:.0} {seen}{tag}",
                    entry.id, entry.bounds.size.width, entry.bounds.size.height
                ));
            }
            if content.display(vd_id).is_some() {
                lines.push(
                    "vd-sck-probe: ✅ SCK ENUMERATES the VD — mintDisplaySession can capture it once it is \
                     main"
                        .to_owned(),
                );
                ProbeVerdict::Enumerated
            } else {
                lines.push(
                    "vd-sck-probe: ❌ SCK did NOT list the VD — the desktop mint cannot target it; needs \
                     another path"
                        .to_owned(),
                );
                ProbeVerdict::Missing
            }
        },
    };
    display.destroy();
    ProbeReport {
        verdict: report,
        lines,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_video::capture_recovery::RECREATE_COOLDOWN_SECONDS;

    use super::{Recreate, SCALE, channels_to_disconnect, geometry};

    #[test]
    fn geometry_scales_points_by_two_and_carries_the_chip_limit() {
        // A base M-series brand takes the tighter limit, so a 3840pt-wide display at 2× — 7680px —
        // is refused up front rather than after a multi-second applySettings stall.
        let tight = geometry(3840, 2160, "Apple M1");
        assert_eq!(tight.scale(), SCALE);
        assert_eq!(tight.pixel_width(), 7680);
        assert!(tight.exceeds_pixel_limit());

        // The same geometry on a Pro part fits.
        let roomy = geometry(3840, 2160, "Apple M1 Pro");
        assert!(!roomy.exceeds_pixel_limit());
    }

    #[test]
    fn an_unreadable_cpu_brand_is_permissive_not_refusing() {
        // The empty string is what the sysctl answers when it FAILS. A machine whose chip cannot be
        // identified must not be refused a display it can probably have — WindowServer decides.
        let unknown = geometry(2560, 1440, "");
        assert!(!unknown.exceeds_pixel_limit());
    }

    #[test]
    fn the_gate_admits_one_flight_and_stamps_the_cooldown_at_begin() {
        let recreate = Recreate::new(geometry(1920, 1080, ""), 60);
        assert!(recreate.begin(100.0), "the first attempt is always admitted");
        assert!(
            !recreate.begin(100.0),
            "a second caller must not join a flight already in progress"
        );
        recreate.end();
        assert!(
            !recreate.begin(100.0 + RECREATE_COOLDOWN_SECONDS - 1.0),
            "inside the cooldown, a retry is refused even with no flight in progress"
        );
        assert!(
            recreate.begin(100.0 + RECREATE_COOLDOWN_SECONDS),
            "the cooldown is measured from the BEGIN of the last attempt, not its end"
        );
        recreate.end();
    }

    #[test]
    fn a_failed_attempt_still_throttles_the_next_one() {
        // `end()` after a refusal must not clear the stamp: otherwise a WindowServer that refuses
        // instantly turns every hello into another eleven-second create attempt.
        let recreate = Recreate::new(geometry(1920, 1080, ""), 60);
        assert!(recreate.begin(0.0));
        recreate.end();
        assert!(!recreate.begin(1.0));
    }

    #[test]
    fn only_channels_that_are_both_parked_and_live_are_disconnected() {
        // 2 and 3 are parked onto the dead display AND still have a lane. 1 is parked but its lane
        // is gone; 4 is live but was never parked, so it captures in place and keeps streaming.
        assert_eq!(
            channels_to_disconnect([3_u32, 1, 2], [4_u32, 3, 2]),
            vec![2, 3],
            "the answer is the intersection, ascending"
        );
        assert!(channels_to_disconnect([], [1_u32, 2]).is_empty());
        assert!(channels_to_disconnect([1_u32, 2], []).is_empty());
    }
}
