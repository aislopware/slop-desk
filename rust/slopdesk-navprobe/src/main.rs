//! `slopdesk-navhistory-probe` — the swipe-nav history reader, against a LIVE app.
//!
//! The reader answers whether the frontmost app can go back and forward, and the chip on the client
//! is gated on it (`docs/20-wire-protocol.md` §9.6). Its DECISIONS — which node counts, how far a
//! walk may go, when a cached pair may still be trusted — are thirteen headless tests in
//! `slopdesk_video::nav_history`. What no test can reach is the other half: the reading is blocking
//! out-of-process accessibility IPC, which hang-safety bars from a suite the way it bars `SCStream`
//! and `VideoToolbox`. So this probe is the only way to exercise the REAL strategy selection
//! (toolbar identifiers vs menu key equivalents), the per-pid element cache and the per-WINDOW
//! currency check — navigate, or switch windows in the target while it runs, and watch the flags
//! follow.
//!
//! Needs the Accessibility grant on the invoking terminal. Exit `0` ⇒ at least one KNOWN read (a
//! strategy found a pair); exit `2` ⇒ every read was unknown; exit `1` ⇒ the target is not running.
//!
//! ## Why it is no longer Swift
//! It was 58 lines of Swift over `HostNavHistory`, which is itself a face over
//! `slopdesk_ffi::nav_history` — so the probe questioned the reader through a marshaller and could
//! only ever prove the marshaller forwarded. Here it holds the reader itself.
//!
//! ```text
//! slopdesk-navhistory-probe [bundle-id] [--pid N] [--seconds N]
//! ```
//!
//! ## PENDING: this crate does not compile until `slopdesk-ffi` grows its Rust face
//! [`SlopDeskNavHistory`] is public but its constructor is `slopdesk_nav_history_new` — a C door —
//! and its `read` is private, so today the reader is reachable only through `unsafe extern "C"`.
//! This crate is `forbid(unsafe_code)` and may not go that way. The change it waits on is two
//! functions in `rust/slopdesk-ffi/src/nav_history.rs`, `reader()` and a `pub` `read`, which is the
//! same "Rust-native face alongside the C door" `slopdesk-loopback-validate` already relies on for
//! the encoder and the decoder. Nothing builds this crate — it is its own workspace, in no `make`
//! target — so it waits harmlessly until that lands.

use std::process::ExitCode;
use std::time::{Duration, Instant};

use slopdesk_ffi::nav_history::SlopDeskNavHistory;

/// The app the probe watches when the caller names none — the browser the gate was built against.
const DEFAULT_BUNDLE: &str = "com.google.Chrome";

/// How long the probe watches when the caller names no duration.
const DEFAULT_SECONDS: f64 = 8.0;

/// The longest watch the probe will accept, so a mistyped `--seconds` cannot overflow the deadline.
const MAX_SECONDS: f64 = 3600.0;

/// The gap between beats. Four a second is the kicker's own change-poll cadence.
const BEAT: Duration = Duration::from_millis(250);

/// One beat in every this many is the FORCED beat: the unknown-retry plus the window-currency
/// verify, mirroring the kicker's heartbeat.
const FORCED_EVERY: u32 = 8;

/// What the caller asked for.
#[derive(Debug)]
struct Options {
    /// The bundle identifier to find, when no pid was given.
    bundle: String,
    /// The pid to read, when the caller already knows it.
    pid: Option<i32>,
    /// How long to watch.
    seconds: f64,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            bundle: DEFAULT_BUNDLE.to_owned(),
            pid: None,
            seconds: DEFAULT_SECONDS,
        }
    }
}

/// The value that follows the flag at `index`, or a message naming the flag that wanted one.
fn value_after(arguments: &[String], index: usize, flag: &str) -> Result<String, String> {
    arguments
        .get(index.saturating_add(1))
        .cloned()
        .ok_or_else(|| format!("{flag} needs a value"))
}

/// Reads the command line, or names the argument it could not.
///
/// A bare argument is the bundle identifier, which is how the Swift instrument read its own command
/// line and how every note that mentions it is written.
fn parse_options() -> Result<Options, String> {
    let mut options = Options::default();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let mut index = 0_usize;
    while let Some(flag) = arguments.get(index) {
        match flag.as_str() {
            "--seconds" => {
                options.seconds = value_after(&arguments, index, flag)?
                    .parse()
                    .map_err(|_| "--seconds is not a number of seconds".to_owned())?;
                index = index.saturating_add(2);
            },
            "--pid" => {
                options.pid = Some(
                    value_after(&arguments, index, flag)?
                        .parse()
                        .map_err(|_| "--pid is not a process id".to_owned())?,
                );
                index = index.saturating_add(2);
            },
            other => {
                other.clone_into(&mut options.bundle);
                index = index.saturating_add(1);
            },
        }
    }
    Ok(options)
}

/// The first running process whose bundle identifier is `bundle`.
///
/// The census is one syscall and the identifier is one `AppKit` lookup per pid; the Swift
/// instrument asked `AppKit` to do both at once, which this crate's `slopdesk-apple-app`
/// deliberately does not expose — the reverse lookup is a search, and a search over a list belongs
/// to the caller holding the list.
fn pid_for_bundle(bundle: &str) -> Option<i32> {
    slopdesk_posix::proc::all_pids()
        .into_iter()
        .find(|pid| slopdesk_apple_app::bundle_id(*pid).is_some_and(|found| found == bundle))
}

/// Watch one app's history flags for a while, and say whether anything was ever known.
fn main() -> ExitCode {
    let options = match parse_options() {
        Ok(options) => options,
        Err(failure) => {
            eprintln!("{failure}");
            return ExitCode::from(1);
        },
    };

    eprintln!("accessibility-trusted={}", slopdesk_apple_ax::is_trusted());

    let Some(pid) = options.pid.or_else(|| pid_for_bundle(&options.bundle)) else {
        eprintln!("app not running: {}", options.bundle);
        return ExitCode::from(2);
    };
    eprintln!("target {} pid {pid}", options.bundle);

    let reader = SlopDeskNavHistory::reader();
    // Bounded because `Duration::from_secs_f64` panics on a negative or non-finite argument and
    // `Instant + Duration` panics on overflow, and a typo in an operator's command line is not a
    // reason for a diagnostic to abort.
    #[expect(
        clippy::manual_clamp,
        reason = "`clamp` PROPAGATES NaN, which is the one input this bound exists to absorb — `max` \
                  answers the non-NaN operand, so `--seconds nan` reads as 0 rather than panicking inside \
                  `Duration::from_secs_f64`"
    )]
    let watched = options.seconds.max(0.0).min(MAX_SECONDS);
    let deadline = Instant::now() + Duration::from_secs_f64(watched);
    let mut beat = 0_u32;
    let mut saw_known = false;
    while Instant::now() < deadline {
        beat = beat.saturating_add(1);
        // The forced beat is the first of each group of eight, exactly as the kicker forces it.
        let forced = beat % FORCED_EVERY == 1;
        let started = Instant::now();
        let flags = reader.read(pid, forced, forced);
        let millis = started.elapsed().as_secs_f64() * 1000.0;
        let reading = flags.map_or_else(
            || "unknown".to_owned(),
            |flags| format!("back={} fwd={}", flags.can_go_back, flags.can_go_forward),
        );
        saw_known = saw_known || flags.is_some();
        eprintln!("beat {beat:2}: {reading} ({millis:.2} ms)");
        std::thread::sleep(BEAT);
    }

    if saw_known {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(2)
    }
}
