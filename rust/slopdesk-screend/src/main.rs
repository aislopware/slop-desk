//! The `slopdesk-screend` entry point: bind the socket, serve until killed.
//!
//! No daemonising, no pid file, no config file. hostd (or launchd) starts it, its stderr is the
//! log, and the socket path comes from `$SLOPDESK_SCREEND_SOCKET` or the single positional argument
//! — the same "the restart is the reload" discipline the rest of the tree runs on.
//!
//! One subcommand breaks that shape, deliberately: `explain`, the differential-parity oracle that
//! `scripts/herdr-differential.py` runs next to upstream's own `herdr agent explain --json`. It
//! needs the compiled rule ladder and nothing else — no socket, no daemon — and it lives on this
//! binary because the ladder does. (It replaced a whole Swift executable target, which existed only
//! because the ladder used to be in Swift.)

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_screend::detect::explain;
use slopdesk_screend::server::{default_socket_path, serve};
use slopdesk_screenwire::HELLO_BANNER;

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let first = args.next();
    if first.as_deref().is_some_and(|arg| arg == "--version") {
        return print_version();
    }
    if first.as_deref().is_some_and(|arg| arg == "explain") {
        return run_explain(args.map(|arg| arg.to_string_lossy().into_owned()).collect());
    }
    let path = first.map_or_else(default_socket_path, PathBuf::from);
    match serve(&path) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("screend: fatal: {error}");
            ExitCode::FAILURE
        },
    }
}

/// `--version`, on stdout because that is where a version belongs — the rest of this daemon's
/// output is a log and goes to stderr.
///
/// ## The format is a contract, not a banner
/// The SECOND whitespace-separated field of the FIRST line is the version, and every tool in the
/// tree answers that shape — `slopdesk version` has since before any of this, and
/// `package-release.sh` has read it that way for as long. That script now asks every shipped
/// binary the same question and refuses to package on a disagreement with
/// `scripts/tool-stamps.pin`, so a crate version bumped in `Cargo.toml` and a binary built from
/// something else cannot both reach a user.
///
/// The parenthetical is the PROTOCOL, which is a different number moving for a different reason:
/// this daemon's version says what code you are running, [`HELLO_BANNER`]'s trailing `1` says what
/// it will agree to speak. A reader who conflates them concludes a patch release requires a client
/// update.
#[expect(clippy::print_stdout, reason = "a --version banner is stdout by convention")]
fn print_version() -> ExitCode {
    let protocol = String::from_utf8_lossy(HELLO_BANNER);
    println!(
        "slopdesk-screend {} (protocol {})",
        env!("CARGO_PKG_VERSION"),
        protocol.rsplit(' ').next().unwrap_or("?"),
    );
    ExitCode::SUCCESS
}

/// `slopdesk-screend explain --file PATH --agent LABEL [--json]`.
///
/// Mirrors `herdr agent explain` argument for argument, including the `--json`/`--format` no-ops,
/// so the differential harness invokes both binaries the same way. Exit 2 on a usage error, which
/// is what the harness treats as "this side could not answer".
#[expect(
    clippy::print_stdout,
    reason = "the trace on stdout IS this subcommand's output — the harness reads it, exactly as it reads \
              upstream's"
)]
fn run_explain(args: Vec<String>) -> ExitCode {
    let mut file = None;
    let mut agent = None;
    let mut rest = args.into_iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--file" => file = rest.next(),
            "--agent" => agent = rest.next(),
            "--json" => {},
            "--format" => {
                rest.next();
            },
            other => return usage(&format!("unknown option: {other}")),
        }
    }
    let (Some(file), Some(agent)) = (file, agent) else {
        return usage("usage: slopdesk-screend explain --file PATH --agent LABEL");
    };
    // A strict UTF-8 read, because upstream's `fs::read_to_string` errors on invalid UTF-8 too.
    let Ok(screen) = std::fs::read_to_string(&file) else {
        return usage(&format!("could not read {file} as UTF-8"));
    };
    match serde_json::to_string(&explain(&agent, &screen)) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        },
        Err(error) => usage(&format!("could not encode the trace: {error}")),
    }
}

fn usage(message: &str) -> ExitCode {
    eprintln!("{message}");
    ExitCode::from(2)
}
