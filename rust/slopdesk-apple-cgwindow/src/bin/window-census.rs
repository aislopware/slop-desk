//! `window-census PID` — how many real on-screen windows the `WindowServer` gives a process.
//!
//! The observer every GUI gate polls after it launches the app, and the reason it is a separate
//! program rather than a function in the gate: the gate binary is `forbid(unsafe_code)` and lives
//! in its own cargo workspace, so it cannot link the `objc2` family. Spawning a probe is already
//! that family's idiom — `lsof`, `pgrep`, `osascript` and `screencapture` are all spawned there —
//! and this is one more, with the difference that this one is ours and compiles with the tree.
//!
//! It replaces the throwaway `swiftc`-compiled census the gates used to carry, which every run
//! `swiftc -O`'d into a temporary directory first.
//!
//! ## The contract three gates poll against, which must not drift
//! stdout is the COUNT and nothing else. stderr is one line per candidate, for a red run's
//! diagnosis. The exit status is 0 even at a count of zero — "no windows" is an ANSWER, and a
//! caller that cannot tell it apart from "the census failed" is the failure this exists to name.
//! Only a usage error, or a platform with no window server at all, exits non-zero.
//!
//! ## What counts as a window
//! Layer 0 and at least [`MIN_SIDE`] points on each side. The `WindowServer` attributes a great
//! deal to an app that is not its UI — pop-up menus at layer 101, the menu bar at 24, and a
//! scattering of tiny status and shadow surfaces at layer 0 — and counting those would make this
//! answer 1 for an app that never opened anything. No window TITLE is read, so no Screen-Recording
//! TCC is needed; owner, layer and bounds are public CoreGraphics fields.
#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the count IS this program's output and the per-window lines ARE its diagnosis"
)]

use std::process::ExitCode;

/// The smallest side, in points, a surface may have and still be the app's UI.
#[cfg(target_os = "macos")]
const MIN_SIDE: f64 = 200.0;

/// The window level an ordinary app window sits at. Menus are 101, the menu bar 24.
#[cfg(target_os = "macos")]
const NORMAL_LAYER: i32 = 0;

/// Count `pid`'s real windows, describing every candidate on the way past.
#[cfg(target_os = "macos")]
fn census(pid: i32) -> ExitCode {
    let mut counted = 0_usize;
    for window in slopdesk_apple_cgwindow::windows_of_pid(pid) {
        let size = window.bounds.size;
        let real = window.layer == NORMAL_LAYER && size.width >= MIN_SIDE && size.height >= MIN_SIDE;
        if real {
            counted += 1;
        }
        eprintln!(
            "  window {} layer={} {}x{} {}",
            window.window_id,
            window.layer,
            size.width,
            size.height,
            if real { "COUNTED" } else { "skipped" }
        );
    }
    println!("{counted}");
    ExitCode::SUCCESS
}

/// No window server, so no answer — and saying `0` here would be a lie a poller waits out.
#[cfg(not(target_os = "macos"))]
fn census(_pid: i32) -> ExitCode {
    eprintln!("window-census: there is no WindowServer on this platform");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let Some(pid) = std::env::args()
        .nth(1)
        .and_then(|argument| argument.parse::<i32>().ok())
    else {
        eprintln!("usage: window-census <pid>");
        return ExitCode::from(2);
    };
    census(pid)
}
