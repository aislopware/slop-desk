//! `slopdesk-guigate` — the four gates that need a real screen.
//!
//! One binary over [`slopdesk_devtools::gui`], one verb per shell script that used to be under
//! `scripts/`. Nothing here decides anything: it parses arguments, resolves the repo root the way
//! every other tool in this crate does, and prints the failure it is handed.
//!
//! None of these is in `make check` and none can be. Each opens windows on the developer's own
//! display for a minute or more, each needs an unlocked Aqua login session, and two need
//! Screen-Recording or Accessibility TCC. They are gates by OUTPUT — the exit status is the verdict
//! and every assertion is machine-checked — and operator harnesses by cost. Run them by hand, after
//! touching what they cover.

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_devtools::gui::{launchrestore, macos, multiclient, video};
use slopdesk_devtools::repo;

/// What the binary answers to.
const USAGE: &str = "\
usage: slopdesk-guigate [--repo-root DIR] <gate> [options]

  macos [--renderer|--connect]          build, window, mount a scene; --connect types a command
                                        that must EXECUTE on the host
  video [--window-title S]              capture -> HEVC -> UDP -> decode -> a Metal drawable
        [--second-client]               …and a second client on the same stream
  multiclient                           two clients, one layout, a real menu gesture between them
  launch-restore                        the launch a USER performs: restore, offer, reattach
  help                                  this text

Each needs an unlocked Aqua session. `video` needs Screen Recording; `multiclient` needs
Accessibility. Neither prompt can be answered from a gate, so grant them once by hand.
";

fn main() -> ExitCode {
    let mut arguments: Vec<String> = std::env::args().skip(1).collect();

    let mut given: Option<PathBuf> = None;
    if arguments.first().is_some_and(|first| first == "--repo-root") {
        if arguments.len() < 2 {
            eprintln!("slopdesk-guigate: --repo-root needs a directory");
            return ExitCode::from(2);
        }
        given = Some(PathBuf::from(arguments.remove(1)));
        arguments.remove(0);
    }
    let root = match repo::root(given.as_deref()) {
        Ok(found) => found,
        Err(why) => {
            eprintln!("slopdesk-guigate: {why}");
            return ExitCode::from(2);
        },
    };

    let Some(gate) = arguments.first().cloned() else {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    };
    let rest = &arguments[1..];

    match gate.as_str() {
        "macos" => {
            match macos::Mode::parse(rest.first().map(String::as_str)) {
                Ok(mode) => finish(macos::run(&root, mode)),
                Err(why) => {
                    eprintln!("slopdesk-guigate: {why}");
                    ExitCode::from(2)
                },
            }
        },
        "video" => run_video(&root, rest),
        "multiclient" => finish(multiclient::run(&root)),
        "launch-restore" => finish(launchrestore::run(&root)),
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        },
        other => {
            eprintln!("slopdesk-guigate: unknown gate: {other}");
            eprint!("{USAGE}");
            ExitCode::from(2)
        },
    }
}

/// A failure is the gate's own sentence on stderr and a non-zero status.
///
/// The message is the gate's, verbatim and unwrapped by a prefix: each one is a full explanation of
/// what was observed and why it is wrong, and the whole point of these four is that a red run needs
/// no second run to diagnose.
fn finish(outcome: Result<(), String>) -> ExitCode {
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            eprintln!("\n==> FAIL: {why}");
            ExitCode::FAILURE
        },
    }
}

/// `video [--window-title S] [--second-client]`.
fn run_video(root: &std::path::Path, arguments: &[String]) -> ExitCode {
    let mut options = video::Options {
        window_title: None,
        second_client: false,
    };
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--window-title" => {
                let Some(title) = arguments.get(index + 1) else {
                    eprintln!("slopdesk-guigate: --window-title needs a title");
                    return ExitCode::from(2);
                };
                options.window_title = Some(title.clone());
                index += 2;
            },
            "--second-client" => {
                options.second_client = true;
                index += 1;
            },
            other => {
                eprintln!("slopdesk-guigate: unknown option for video: {other}");
                return ExitCode::from(2);
            },
        }
    }
    finish(video::run(root, &options))
}
