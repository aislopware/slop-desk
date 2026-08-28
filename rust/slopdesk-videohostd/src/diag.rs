//! The one way this daemon says anything to whoever started it.
//!
//! The Swift daemon's `log`, which every file in that host reached for by closure capture. One
//! function here instead, for the three properties that closure had and that are easy to lose when
//! a second one appears.
//!
//! ## Everything goes to stderr, including the listings
//! `--list` prints its windows here, not to stdout. That is deliberate and it is the Swift's: a
//! diagnostic stream that splits across two file descriptors is the one inconsistency an operator
//! notices, because it is the one that survives their redirect and reorders itself.
//!
//! ## One `write_all` of one buffer
//! Two writes can interleave with another thread's, and this daemon writes from the mint thread,
//! the receive threads and the reaper. The buffer is built first and handed over whole, so a line
//! is a line.
//!
//! ## The prefix is the name the process was INVOKED under
//! Not a constant. Two daemons on one machine — a release and the one being tested — are told apart
//! in a shared log by exactly this, and a hardcoded name would make the two indistinguishable at
//! the moment an operator most needs them separated.

use std::io::Write as _;
use std::sync::OnceLock;

/// The name to fall back to when `argv[0]` says nothing usable.
const FALLBACK: &str = "slopdesk-videohostd";

/// The resolved prefix, computed once. Read from every thread that logs, which is most of them.
static PROGRAM: OnceLock<String> = OnceLock::new();

/// The basename this process was invoked under.
///
/// Resolved on first use rather than at start-up so that no caller has to be handed it, and so a
/// diagnostic from a path that runs before `main` has arranged anything still comes out labelled.
#[must_use]
pub fn program() -> &'static str {
    PROGRAM.get_or_init(|| {
        std::env::args_os()
            .next()
            .as_ref()
            .map(std::path::Path::new)
            .and_then(std::path::Path::file_name)
            .and_then(std::ffi::OsStr::to_str)
            .filter(|name| !name.is_empty())
            .unwrap_or(FALLBACK)
            .to_owned()
    })
}

/// One diagnostic line on stderr.
///
/// Best-effort by construction: a daemon whose stderr has gone away — a launchd job whose log was
/// rotated out from under it — has nothing useful to do about it and must not fail a mint over it.
pub fn say(message: &str) {
    let _ignored = std::io::stderr().write_all(format!("{}: {message}\n", program()).as_bytes());
}
