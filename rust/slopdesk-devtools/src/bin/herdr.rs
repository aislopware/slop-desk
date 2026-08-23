//! `slopdesk-herdr` — the upstream sync and the parity harness, in one program.
//!
//! Two subcommands, because they are two halves of one operation and `slopdesk-ops herdr-sync` runs
//! both back to back:
//!
//!   slopdesk-herdr manifests [--herdr-dir PATH] [--check]
//!   slopdesk-herdr differential [--herdr-dir PATH] [--seed N] [--jobs N] [--max-report N]
//!
//! `manifests --check` exits nonzero (without writing) when a checked-in manifest differs from
//! upstream. `differential` exits 0 on full parity over the corpus and 1 on any mismatch it cannot
//! attribute to a deliberately diverged rule.

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_devtools::differential::{self, Options};
use slopdesk_devtools::{manifests, repo};

/// The usage line, which is also the error for an unknown subcommand.
const USAGE: &str = "usage: slopdesk-herdr <manifests|differential> [options]\n  manifests    [--herdr-dir \
                     PATH] [--check]\n  differential [--herdr-dir PATH] [--seed N] [--jobs N] [--max-report \
                     N]\n  both also take [--repo-root PATH]";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match dispatch(&arguments) {
        Ok(code) => code,
        Err(complaint) => {
            eprintln!("{complaint}");
            ExitCode::FAILURE
        },
    }
}

/// Read the flags, run the subcommand, and turn its verdict into an exit code.
fn dispatch(arguments: &[String]) -> Result<ExitCode, String> {
    let Some(subcommand) = arguments.first() else {
        return Err(USAGE.to_owned());
    };
    let flags = Flags::read(arguments.get(1..).unwrap_or(&[]))?;
    let root = repo::root(flags.repo_root.as_deref())?;
    let herdr_dir = flags.herdr_dir.clone().unwrap_or_else(repo::default_herdr_dir);
    if !herdr_dir.join("src/detect/manifests").is_dir() {
        return Err(format!("not a herdr checkout: {}", herdr_dir.display()));
    }

    match subcommand.as_str() {
        "manifests" => {
            let outcome = manifests::sync(&root, &herdr_dir, flags.check)?;
            for note in &outcome.notes {
                println!("{note}");
            }
            Ok(if outcome.drift {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            })
        },
        "differential" => differential_run(&root, &herdr_dir, &flags),
        other => Err(format!("unknown subcommand {other:?}\n{USAGE}")),
    }
}

/// Run the parity harness and print its report.
fn differential_run(
    root: &std::path::Path,
    herdr_dir: &std::path::Path,
    flags: &Flags,
) -> Result<ExitCode, String> {
    let screend = root.join("rust/slopdesk-screend");
    // Release first, debug as the fallback, so a dev loop that only ran `cargo build` still has an
    // oracle. The ported engine's `explain` is a SUBCOMMAND of the daemon binary, not a target of
    // its own: the rule ladder lives in `rust/slopdesk-screend` and an explain that did not share
    // its code would be a second engine to keep honest (`docs/52-screen-engine.md`).
    let port_bin = [
        screend.join("target/release/slopdesk-screend"),
        screend.join("target/debug/slopdesk-screend"),
    ]
    .into_iter()
    .find(|candidate| candidate.exists())
    .unwrap_or_else(|| screend.join("target/release/slopdesk-screend"));

    let pin_path = root.join("scripts/herdr.pin");
    let head = std::process::Command::new("git")
        .arg("-C")
        .arg(herdr_dir)
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .unwrap_or_default();
    let pin = std::fs::read_to_string(&pin_path)
        .map_or_else(|_| "(no pin)".to_owned(), |text| text.trim().to_owned());
    if head != pin {
        println!(
            "note: herdr checkout {} != pinned {} (fine during a sync run)",
            short(&head),
            short(&pin)
        );
    }

    let options = Options {
        herdr_dir: herdr_dir.to_path_buf(),
        herdr_bin: herdr_dir.join("target/release/herdr"),
        port_bin,
        seed: flags.seed,
        jobs: flags.jobs,
        max_report: flags.max_report,
    };
    let report = differential::run(&options, &|line| println!("{line}"))?;
    if report.mismatches.is_empty() {
        println!(
            "PARITY OK: {} cases, herdr ≡ slopdesk on every compared field",
            report.cases
        );
        return Ok(ExitCode::SUCCESS);
    }
    println!(
        "MISMATCH: {}/{} cases diverged",
        report.mismatches.len(),
        report.cases
    );
    for mismatch in report.mismatches.iter().take(flags.max_report) {
        println!(
            "\n=== agent={} screen={:?}",
            mismatch.label,
            mismatch.screen.chars().take(120).collect::<String>()
        );
        println!("{}", mismatch.detail);
    }
    if report.mismatches.len() > flags.max_report {
        println!("\n… and {} more", report.mismatches.len() - flags.max_report);
    }
    Ok(ExitCode::FAILURE)
}

/// The first twelve characters of a commit, or the whole thing when it is shorter.
fn short(sha: &str) -> String {
    sha.chars().take(12).collect()
}

/// Everything both subcommands can be told.
#[derive(Debug)]
struct Flags {
    repo_root: Option<PathBuf>,
    herdr_dir: Option<PathBuf>,
    check: bool,
    seed: u64,
    jobs: usize,
    max_report: usize,
}

impl Flags {
    /// The defaults, which are the ones `slopdesk-ops herdr-sync` relies on.
    fn read(arguments: &[String]) -> Result<Self, String> {
        let mut flags = Self {
            repo_root: None,
            herdr_dir: None,
            check: false,
            seed: 20_260_724,
            jobs: 8,
            max_report: 12,
        };
        let mut at = 0;
        while let Some(flag) = arguments.get(at) {
            let value = || {
                arguments
                    .get(at + 1)
                    .ok_or_else(|| format!("{flag} needs a value\n{USAGE}"))
            };
            let mut took_a_value = true;
            match flag.as_str() {
                "--check" => {
                    flags.check = true;
                    took_a_value = false;
                },
                "--repo-root" => flags.repo_root = Some(PathBuf::from(value()?)),
                "--herdr-dir" => flags.herdr_dir = Some(PathBuf::from(value()?)),
                "--seed" => flags.seed = number(value()?, flag)?,
                "--jobs" => flags.jobs = number(value()?, flag)?,
                "--max-report" => flags.max_report = number(value()?, flag)?,
                other => return Err(format!("unknown flag {other:?}\n{USAGE}")),
            }
            at += if took_a_value { 2 } else { 1 };
        }
        Ok(flags)
    }
}

/// A flag's numeric value, with the flag named when it is not one.
fn number<T: std::str::FromStr>(written: &str, flag: &str) -> Result<T, String> {
    written
        .parse()
        .map_err(|_| format!("{flag} wants a number, not {written:?}"))
}
