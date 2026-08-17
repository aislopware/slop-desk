//! `slopdesk-agenthooks` — installs, removes and reports the Claude Code hooks.
//!
//! ## The interface
//! One subcommand per question, one JSON object on stdout per answer — the same shape
//! `slopdesk-codeseed` answers hostd in, and for the same reason: two of the three answers carry a
//! path the caller prints, and a caller that has to guess where a field ends will eventually guess
//! wrong.
//!
//! ```text
//! install   → {"settings": "…", "hook": "…"}      exit 0
//! uninstall → {"settings": "…"}                   exit 0
//! status    → {"installed": bool, "settings": "…", "hook": "…"}
//! ```
//!
//! Failure is `{"error": "…"}` and a non-zero exit. Only `install` and `uninstall` can fail, and
//! only at the two steps that can lose something — staging the relay and writing the settings file.
//! `status` has no failure: an unreadable settings file is not installed.
//!
//! Every path is resolved from THIS process's environment, which is hostd's, which is the one a
//! `claude` in a pane inherits. That is the whole reason the resolution lives behind a subcommand
//! instead of being spelled twice: one program decides, from the environment that actually applies.
//!
//! ## The relay it installs is its SIBLING
//! `install` copies the `slopdesk-hook` sitting beside this binary. They are built from one crate
//! by one `make hook` and staged into one directory, so "beside me" is the only resolution that
//! cannot name a relay from a different build than the marker it was compiled against.

use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::{Value, json};
use slopdesk_hook::install;

#[expect(
    clippy::print_stdout,
    reason = "stdout IS this program's return value; the relay's ban on printing stays in force because it \
              is a different binary"
)]
fn main() -> ExitCode {
    let Some(subcommand) = std::env::args().nth(1) else {
        println!("{}", usage());
        return ExitCode::FAILURE;
    };
    // Ahead of the path resolution, because "which one is installed" is asked precisely when the
    // environment is the thing in doubt. The SECOND whitespace-separated field of the FIRST line is
    // the version — the shape every tool in this tree answers and the one `package-release.sh`
    // parses when it checks a built binary against `scripts/tool-stamps.pin`.
    //
    // NOT the JSON this program's real subcommands return: a version banner is read by a human and
    // by one `awk` in the packaging script, and wrapping it in an object would make both work
    // harder for nothing.
    if subcommand == "--version" {
        println!("slopdesk-agenthooks {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    let environment = install::process_environment();
    let home = install::home_in(&environment);
    let settings = install::settings_path(&environment, &home);
    let hook = install::hook_path(&environment, &home);

    let answer = match subcommand.as_str() {
        "install" => {
            relay_beside_me().map_or_else(
                || {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::NotFound,
                        "cannot resolve this binary's own directory to find the relay beside it",
                    ))
                },
                |relay| {
                    install::install(&settings, &hook, &relay).map(|_written| {
                        json!({
                            "settings": settings.display().to_string(),
                            "hook": hook.display().to_string(),
                        })
                    })
                },
            )
        },
        "uninstall" => {
            install::uninstall(&settings)
                .map(|_written| json!({ "settings": settings.display().to_string() }))
        },
        "status" => {
            Ok(json!({
                "installed": install::is_installed(&settings),
                "settings": settings.display().to_string(),
                "hook": hook.display().to_string(),
            }))
        },
        _ => {
            println!("{}", usage());
            return ExitCode::FAILURE;
        },
    };

    match answer {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        },
        Err(error) => {
            // The error goes out on stdout with everything else: the caller reads one stream and
            // decodes one object, and a failure it has to look somewhere else for is a failure it
            // will report as "no answer" rather than as what went wrong.
            println!("{}", json!({ "error": error.to_string() }));
            ExitCode::FAILURE
        },
    }
}

/// The relay staged in the same directory as this binary. `None` only when the running executable's
/// own path cannot be resolved, which on this platform means the file was unlinked underneath us.
fn relay_beside_me() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    Some(executable.parent()?.join(install::RELAY_NAME))
}

/// The usage text, on stdout with the rest of this program's output — a caller that mis-invoked it
/// is reading the same stream either way.
fn usage() -> Value {
    json!({ "error": "usage: slopdesk-agenthooks <install|uninstall|status>" })
}
