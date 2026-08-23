//! `slopdesk-ops` — the harnesses a developer runs by hand.
//!
//! One binary over [`slopdesk_devtools::ops`], one verb per thing that used to be a shell script.
//! Nothing here decides anything: it parses arguments, resolves the repo root the way every other
//! tool in this crate does, and prints the failure it is handed.
//!
//! These are NOT gates. Every verb changes the machine or the working tree — it installs a
//! `LaunchAgent`, restarts a live daemon, rewrites a generated `project.yml`, re-downloads a
//! vendor's themes, or drives an eighty-second soak — which is why none of them is in `make check`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use slopdesk_devtools::ops::{codeserver, herdr, hostd, launchd, monokai, renderer, soak, videoinput};
use slopdesk_devtools::repo;

/// What the binary answers to.
const USAGE: &str = "\
usage: slopdesk-ops [--repo-root DIR] <verb> [options]

  restart-hostd [--no-build] [--stop] [--status]
                                        rebuild, stop and restart the recorded hostd
  install <superd|screend> [--force] [--uninstall]
                                        the LaunchAgent for a sidecar daemon
  enable-renderer <macos|ios>           wire the ghostty renderer into a client spec
  regenerate <macos|ios>                regenerate a spec's .xcodeproj (the restore half)
  monokai-sync [--latest]               re-sync the code panel's themes from the marketplace
  herdr-sync [--update-pin] [REF]       prove detect-engine parity against upstream herdr
  measure-code-server [RUNS]            spawn → listening latency, RUNS times (default 3)
  video-input [--window-id N] -- ARGS…  one synthetic gesture, then the injection trace
  soak [--threshold BYTES]              the fan-out laggard soak (~80s, needs a real PTY)
  help                                  this text
";

fn main() -> ExitCode {
    let mut arguments: Vec<String> = std::env::args().skip(1).collect();

    // The reaper is answered before the repo root is resolved: it is this binary re-executed by the
    // soak with nothing but a pid file and a scratch directory, and it must still run when the tree
    // it was started from has been moved out from under it.
    if arguments.first().is_some_and(|first| first == "soak-reap") {
        return soak_reap(&arguments[1..]);
    }

    let mut given: Option<PathBuf> = None;
    if arguments.first().is_some_and(|first| first == "--repo-root") {
        if arguments.len() < 2 {
            eprintln!("slopdesk-ops: --repo-root needs a directory");
            return ExitCode::from(2);
        }
        given = Some(PathBuf::from(arguments.remove(1)));
        arguments.remove(0);
    }
    let root = match repo::root(given.as_deref()) {
        Ok(found) => found,
        Err(why) => {
            eprintln!("slopdesk-ops: {why}");
            return ExitCode::from(2);
        },
    };

    let Some(verb) = arguments.first().cloned() else {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    };
    let rest = &arguments[1..];

    match verb.as_str() {
        "restart-hostd" => restart_hostd(&root, rest),
        "install" => install(&root, rest),
        "enable-renderer" => with_target(rest, |target| renderer::enable(&root, target)),
        "regenerate" => with_target(rest, |target| renderer::generate(&root, &root.join(target.spec))),
        "monokai-sync" => finish(monokai::run(&root, has_flag(rest, "--latest"))),
        "herdr-sync" => herdr_sync(&root, rest),
        "measure-code-server" => measure_code_server(&root, rest),
        "video-input" => video_input(&root, rest),
        "soak" => run_soak(&root, rest),
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        },
        other => {
            eprintln!("slopdesk-ops: unknown verb: {other}");
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
            eprintln!("slopdesk-ops: {why}");
            ExitCode::FAILURE
        },
    }
}

/// True when a bare flag is present.
fn has_flag(arguments: &[String], flag: &str) -> bool {
    arguments.iter().any(|argument| argument == flag)
}

/// `restart-hostd [--no-build] [--stop] [--status]` — the later flag wins, as the shell's `case`
/// did.
fn restart_hostd(root: &Path, arguments: &[String]) -> ExitCode {
    let mut plan = hostd::Plan::FULL;
    for argument in arguments {
        match argument.as_str() {
            "--no-build" => plan.build = false,
            "--stop" => {
                plan = hostd::Plan {
                    build: false,
                    stop: true,
                    start: false,
                }
            },
            "--status" => plan = hostd::Plan::STATUS,
            other => {
                eprintln!("slopdesk-ops: unknown option for restart-hostd: {other}");
                return ExitCode::from(2);
            },
        }
    }
    finish(hostd::run(root, plan))
}

/// `install <superd|screend> [--force] [--uninstall]`.
fn install(root: &Path, arguments: &[String]) -> ExitCode {
    let Some(name) = arguments.first() else {
        eprintln!("slopdesk-ops: install needs a daemon name (superd or screend)");
        return ExitCode::from(2);
    };
    let agent = match launchd::by_name(name) {
        Ok(found) => found,
        Err(why) => {
            eprintln!("slopdesk-ops: {why}");
            return ExitCode::from(2);
        },
    };
    let rest = &arguments[1..];
    let force = has_flag(rest, "--force");
    for argument in rest {
        if argument != "--force" && argument != "--uninstall" {
            eprintln!("slopdesk-ops: unknown option for install: {argument}");
            return ExitCode::from(2);
        }
    }
    if has_flag(rest, "--uninstall") {
        finish(launchd::uninstall(agent, force))
    } else {
        finish(launchd::install(root, agent, force))
    }
}

/// The two verbs that take a renderer target name and nothing else.
fn with_target<F>(arguments: &[String], act: F) -> ExitCode
where
    F: FnOnce(&'static renderer::Target) -> Result<(), String>,
{
    let Some(name) = arguments.first() else {
        eprintln!("slopdesk-ops: this verb needs a target (macos or ios)");
        return ExitCode::from(2);
    };
    match renderer::by_name(name) {
        Ok(target) => finish(act(target)),
        Err(why) => {
            eprintln!("slopdesk-ops: {why}");
            ExitCode::from(2)
        },
    }
}

/// `herdr-sync [--update-pin] [REF]` — anything that is not the flag is the upstream ref.
fn herdr_sync(root: &Path, arguments: &[String]) -> ExitCode {
    let update_pin = has_flag(arguments, "--update-pin");
    let target = arguments
        .iter()
        .find(|argument| *argument != "--update-pin")
        .cloned()
        .unwrap_or_else(|| "origin/master".to_owned());
    let checkout = std::env::var_os("HERDR_DIR").map_or_else(
        || slopdesk_devtools::ops::home().join(".cache/clio-repos/github.com--ogulcancelik--herdr"),
        PathBuf::from,
    );
    finish(herdr::run(root, &checkout, &target, update_pin))
}

/// `measure-code-server [RUNS]`.
fn measure_code_server(root: &Path, arguments: &[String]) -> ExitCode {
    let runs = match arguments.first() {
        None => 3,
        Some(given) => {
            match given.parse::<u32>() {
                Ok(runs) if runs > 0 => runs,
                _ => {
                    eprintln!("slopdesk-ops: measure-code-server takes a positive run count, got {given}");
                    return ExitCode::from(2);
                },
            }
        },
    };
    finish(codeserver::run(root, runs))
}

/// `video-input [--window-id N] [--] ARGS…` — everything after the window id goes to the synclient.
fn video_input(root: &Path, arguments: &[String]) -> ExitCode {
    let mut window = std::env::var("WID").unwrap_or_else(|_| "267".to_owned());
    let mut rest = arguments;
    if rest.first().is_some_and(|first| first == "--window-id") {
        let Some(given) = rest.get(1) else {
            eprintln!("slopdesk-ops: --window-id needs a window id");
            return ExitCode::from(2);
        };
        window.clone_from(given);
        rest = &rest[2..];
    }
    if rest.first().is_some_and(|first| first == "--") {
        rest = &rest[1..];
    }
    finish(videoinput::run(root, &window, rest))
}

/// `soak [--threshold BYTES]` — the exit status is the number of properties that FAILED.
///
/// A failing property is not an error: all four run, all four report, and the count is the status,
/// so one failure cannot hide the other three.
fn run_soak(root: &Path, arguments: &[String]) -> ExitCode {
    let mut threshold = std::env::var("SLOPDESK_SUB_LAG_BYTES")
        .ok()
        .and_then(|given| given.parse::<u64>().ok())
        .unwrap_or(soak::DEFAULT_THRESHOLD);
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--threshold" => {
                let Some(given) = arguments.get(index + 1).and_then(|text| text.parse::<u64>().ok()) else {
                    eprintln!("slopdesk-ops: --threshold needs a byte count");
                    return ExitCode::from(2);
                };
                threshold = given;
                index += 2;
            },
            other => {
                eprintln!("slopdesk-ops: unknown option for soak: {other}");
                return ExitCode::from(2);
            },
        }
    }
    match soak::run(root, threshold) {
        Ok(0) => ExitCode::SUCCESS,
        Ok(failures) => ExitCode::from(u8::try_from(failures).unwrap_or(u8::MAX)),
        Err(why) => {
            eprintln!("slopdesk-ops: {why}");
            ExitCode::from(2)
        },
    }
}

/// `soak-reap --pidfile FILE --work DIR` — the soak's own cleanup, re-executed as a child.
fn soak_reap(arguments: &[String]) -> ExitCode {
    let mut pidfile = PathBuf::new();
    let mut work = PathBuf::new();
    let mut index = 0;
    while index + 1 < arguments.len() {
        match arguments[index].as_str() {
            "--pidfile" => pidfile = PathBuf::from(&arguments[index + 1]),
            "--work" => work = PathBuf::from(&arguments[index + 1]),
            other => {
                eprintln!("slopdesk-ops: unknown option for soak-reap: {other}");
                return ExitCode::from(2);
            },
        }
        index += 2;
    }
    if pidfile.as_os_str().is_empty() || work.as_os_str().is_empty() {
        eprintln!("slopdesk-ops: soak-reap needs --pidfile and --work");
        return ExitCode::from(2);
    }
    finish(soak::reap(&pidfile, &work))
}
