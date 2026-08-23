//! `slopdesk-gate` — the seven gates that had to build, boot or execute something.
//!
//! One binary, one verb per gate, and the deciding half of each in [`slopdesk_devtools::gates`]
//! with tests beside it. Every verb resolves the repo root the same way and prints its own failure;
//! nothing here decides anything.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use slopdesk_devtools::gates::{android, golden, prepush, touched, xcode};
use slopdesk_devtools::repo;

/// What the binary answers to.
const USAGE: &str = "\
usage: slopdesk-gate [--repo-root DIR] <verb> [options]

  test-touched [--dry-run] [TARGET...]  build incrementally, run only the tests the change reaches
  pre-push                              the full suite, with the green-tree cache
  golden                                the wire corpus, byte for byte
  ios [--force]                         iOS-triple typecheck (stamped)
  macos-apps [--force]                  macOS app-shell typecheck (stamped)
  ios-tests [--device NAME] [--keep-booted]
                                        RUN the iOS tests on a simulator
  android                               the Android hardware gate (needs a device)
  help                                  this text
";

fn main() -> ExitCode {
    let mut arguments: Vec<String> = std::env::args().skip(1).collect();

    let mut given: Option<PathBuf> = None;
    if arguments.first().is_some_and(|first| first == "--repo-root") {
        if arguments.len() < 2 {
            eprintln!("slopdesk-gate: --repo-root needs a directory");
            return ExitCode::from(2);
        }
        given = Some(PathBuf::from(arguments.remove(1)));
        arguments.remove(0);
    }
    let root = match repo::root(given.as_deref()) {
        Ok(found) => found,
        Err(why) => {
            eprintln!("slopdesk-gate: {why}");
            return ExitCode::from(2);
        },
    };

    let Some(verb) = arguments.first().cloned() else {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    };
    let rest = &arguments[1..];

    match verb.as_str() {
        "test-touched" => test_touched(&root, rest),
        "pre-push" => finish(prepush::run(&root)),
        "golden" => finish(golden::run(&root)),
        "ios" => finish(xcode::ios_typecheck(&root, has_flag(rest, "--force"))),
        "macos-apps" => finish(xcode::macos_apps_typecheck(&root, has_flag(rest, "--force"))),
        "ios-tests" => ios_tests(&root, rest),
        "android" => finish(android::run(&root)),
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        },
        other => {
            eprintln!("slopdesk-gate: unknown verb: {other}");
            eprint!("{USAGE}");
            ExitCode::from(2)
        },
    }
}

/// A failure is one line on stderr and a non-zero status; a success says nothing extra.
fn finish(outcome: Result<(), String>) -> ExitCode {
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            eprintln!("{why}");
            ExitCode::FAILURE
        },
    }
}

/// True when a bare flag is present.
fn has_flag(arguments: &[String], flag: &str) -> bool {
    arguments.iter().any(|argument| argument == flag)
}

/// `test-touched [--dry-run] [TARGET...]` — explicit targets override the attribution entirely.
fn test_touched(root: &Path, arguments: &[String]) -> ExitCode {
    let dry_run = has_flag(arguments, "--dry-run");
    let explicit: Vec<String> = arguments
        .iter()
        .filter(|argument| *argument != "--dry-run")
        .cloned()
        .collect();
    finish(touched::run(root, dry_run, &explicit))
}

/// `ios-tests [--device NAME] [--keep-booted]`.
fn ios_tests(root: &Path, arguments: &[String]) -> ExitCode {
    let mut request = xcode::SimulatorRequest::default();
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--device" => {
                let Some(name) = arguments.get(index + 1) else {
                    eprintln!("slopdesk-gate: --device needs a name");
                    return ExitCode::from(2);
                };
                request.device.clone_from(name);
                index += 2;
            },
            "--keep-booted" => {
                request.keep_booted = true;
                index += 1;
            },
            other => {
                eprintln!("slopdesk-gate: unknown option for ios-tests: {other}");
                return ExitCode::from(2);
            },
        }
    }
    finish(xcode::ios_tests(root, &request))
}
