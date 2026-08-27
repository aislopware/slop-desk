//! `slopdesk-videohostd` — the GUI-video host daemon.
//!
//! ## What a `main` is allowed to be
//! An ORDER and nothing else. Every decision below this file is somebody's — a gate's, a policy's,
//! a ladder's — and the only thing that cannot live anywhere else is the sequence they happen in.
//! So there is no logic here beyond "this before that", and each "before" carries the reason it is
//! not the other way round.
//!
//! ## The order, and what each step depends on
//! 1. **Fold the settings sidecar**, as the FIRST act. `docs/58`: there is no settings GUI and no
//!    live reload, so a toggle applies at the next launch and this is that launch. It runs before
//!    the arg parse because `SLOPDESK_VD` is one of the keys it can carry, and the parse resolves
//!    that knob.
//! 2. **Parse argv.** A usage failure must cost nothing — no socket, no stream, no window server
//!    query — so it happens before anything with an effect.
//! 3. The one-shot modes, before the daemon proper: `--list` and `--vd-sck-probe` both answer a
//!    question and exit, and neither should bind a port to do it.
//!
//! ⚠️ GUI + TCC ONLY — see [`slopdesk_videohostd`]'s own docs. Run from a desktop session, not SSH.

use std::io::Write as _;

use slopdesk_videohostd::args::{Arguments, Usage};
use slopdesk_videohostd::env::Overlay;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    let program = argv
        .first()
        .and_then(|path| std::path::Path::new(path).file_name())
        .and_then(std::ffi::OsStr::to_str)
        .unwrap_or("slopdesk-videohostd")
        .to_owned();

    // Step 1. Before the parse, because `SLOPDESK_VD` is a key this file can carry.
    let overlay = Overlay::from_launch();
    let applied = overlay.applied();
    if !applied.is_empty() && std::env::var_os("SLOPDESK_VIDEO_DEBUG").is_some() {
        say(
            &program,
            &format!("applied video-prefs.json overlay → {applied:?}"),
        );
    }

    // Step 2. A usage failure costs nothing.
    let vd = overlay.get("SLOPDESK_VD");
    let Some(parsed) = Arguments::parse(&argv, vd.as_deref()) else {
        let _ignored = std::io::stderr().write_all(format!("{}\n", Usage(&program)).as_bytes());
        std::process::exit(2);
    };

    // Step 3. The one-shot modes. Each answers a question and exits; neither binds a port.
    //
    // The daemon proper lands with the session that runs under it — see `docs/60` for the ladder
    // this crate is working down. Until then an invocation that asks for the daemon says so rather
    // than pretending to serve.
    drop(parsed);
    say(&program, "the serving path is not wired up in this crate yet");
    std::process::exit(1);
}

/// One diagnostic line on stderr, prefixed with the name the process was invoked under.
///
/// ONE `write_all` of ONE buffer, deliberately: two writes can interleave with another thread's.
fn say(program: &str, message: &str) {
    let _ignored = std::io::stderr().write_all(format!("{program}: {message}\n").as_bytes());
}
