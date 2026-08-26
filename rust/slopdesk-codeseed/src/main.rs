//! `slopdesk-codeseed` — hostd's answer for every question about the code panel's profile.
//!
//! ## The interface
//! One subcommand per question, one JSON object on stdout per answer. JSON rather than bare lines
//! because three of the six answers are already structured (a path map, an argv list, a delta of
//! environment pairs), and a caller that has to guess where a list ends is a caller that will
//! eventually guess wrong.
//!
//! Exit status is **0 for a question answered**, whatever the answer — a seed that changed nothing
//! is not a failure, it is the steady state. Non-zero means the ARGUMENTS were unusable, which is
//! a bug in the caller rather than a state of the profile.
//!
//! ```text
//! seed                                          → {"changed": bool}
//! launch-args                                   → {"arguments": [...]}
//! child-env                                     → {"environment": [[key, value], ...]}
//! missing-extensions                            → {"missing": [...]}
//! sync-font --family F --size S --line-height H → {"changed": bool}
//! paths                                         → {"dataDir":…, "userSettings":…,
//!                                                  "extensionsDir":…, "bridgeSocket":…}
//! ```
//!
//! Every path answer is resolved from THIS process's environment, which is hostd's — the same
//! environment the code-server child will inherit. That is the whole reason the resolution lives
//! behind a subcommand instead of being duplicated in Swift: one program decides, and it decides
//! from the environment the child actually gets.

use std::process::ExitCode;

use serde_json::{Value, json};
use slopdesk_codeseed::{extensions, launch, paths, settings};

// stdout IS this program's return value: hostd reads one JSON object off it per invocation, so
// the lint would be firing on the interface itself. Three functions write that stream and they
// are the three carrying this — a fourth `println!` anywhere else is a bug, not an answer.
#[expect(clippy::print_stdout, reason = "stdout is this program's answer to hostd")]
fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(subcommand) = arguments.first() else {
        return usage();
    };
    if subcommand == "--version" {
        return print_version();
    }
    let environment = paths::process_environment();
    let answer = match subcommand.as_str() {
        "seed" => {
            json!({
                "changed": slopdesk_codeseed::seed_profile(&paths::data_dir_in(&environment)),
            })
        },
        "launch-args" => json!({ "arguments": launch::arguments() }),
        "child-env" => {
            json!({
                "environment": launch::environment_additions(&environment)
                    .into_iter()
                    .map(|(key, value)| Value::Array(vec![Value::String(key), Value::String(value)]))
                    .collect::<Vec<_>>(),
            })
        },
        "missing-extensions" => {
            json!({
                "missing": extensions::missing_bundled_extensions_at(
                    &paths::extensions_dir_in(&environment),
                ),
            })
        },
        "sync-font" => {
            match sync_font(&arguments, &environment) {
                Some(answer) => answer,
                None => return usage(),
            }
        },
        "paths" => {
            json!({
                "dataDir": paths::data_dir_in(&environment).to_string_lossy(),
                "userSettings": paths::user_settings_in(&environment).to_string_lossy(),
                "extensionsDir": paths::extensions_dir_in(&environment).to_string_lossy(),
                "bridgeSocket": paths::bridge_socket_in(&environment).to_string_lossy(),
            })
        },
        _ => return usage(),
    };
    println!("{answer}");
    ExitCode::SUCCESS
}

/// `sync-font --family F --size S --line-height H`.
///
/// All three are required and none has a default: a font sync with a guessed size would write a
/// number the client never asked for into a file the operator reads. `None` ⇒ the caller is wrong,
/// and the usage text is the answer.
fn sync_font(arguments: &[String], environment: &paths::Environment) -> Option<Value> {
    let mut family: Option<String> = None;
    let mut size: Option<f64> = None;
    let mut line_height: Option<f64> = None;
    let mut rest = arguments.iter().skip(1);
    while let Some(flag) = rest.next() {
        let value = rest.next()?;
        match flag.as_str() {
            "--family" => family = Some(value.clone()),
            "--size" => size = Some(value.parse().ok()?),
            "--line-height" => line_height = Some(value.parse().ok()?),
            _ => return None,
        }
    }
    let changed = settings::sync_editor_font(
        &paths::user_settings_in(environment),
        &family?,
        size?,
        line_height?,
    );
    Some(json!({ "changed": changed }))
}

/// `--version`, on stdout with the rest of this program's output.
///
/// The SECOND whitespace-separated field of the FIRST line is the version, which is the shape
/// every tool in this tree answers and the one `slopdesk-release package` parses when it checks a
/// built binary against `scripts/tool-stamps.pin`.
///
/// The parenthetical names the two artefacts this program WRITES into the workbench profile, and
/// they are why it needs a version banner at all despite speaking no wire: it is not a daemon
/// anyone restarts, it is a seeder whose output outlives every run. A profile seeded by an older
/// codeseed keeps that theme and that bridge until something reseeds it, so "which codeseed wrote
/// this profile" is a question with real consequences, and these three numbers are its answer.
#[expect(
    clippy::print_stdout,
    reason = "the banner is this program's answer to `--version`"
)]
fn print_version() -> ExitCode {
    println!(
        "slopdesk-codeseed {} (theme {}, bridge {})",
        env!("CARGO_PKG_VERSION"),
        extensions::THEME_VERSION,
        extensions::BRIDGE_VERSION,
    );
    ExitCode::SUCCESS
}

/// The usage text, on stdout with the rest of this program's output — a caller that mis-invoked it
/// is reading the same stream either way, and `print_stderr` is denied here for that reason.
#[expect(
    clippy::print_stdout,
    reason = "usage shares the one stream this program answers on"
)]
fn usage() -> ExitCode {
    println!(
        "usage: slopdesk-codeseed <seed|launch-args|child-env|missing-extensions|paths|sync-font --family F \
         --size S --line-height H>"
    );
    ExitCode::FAILURE
}
