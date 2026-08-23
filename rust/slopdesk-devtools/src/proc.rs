//! Running the tools a release still needs, and nothing more.
//!
//! What survives the port to Rust is exactly what a compiled program cannot do itself: `xcodebuild`
//! builds an app bundle, `codesign` talks to a keychain, `notarytool` talks to Apple, `git` and
//! `git-cliff` read the object database. Everything the shell did BESIDES spawning — the parsing,
//! the arithmetic, the digests, the string rewriting — is a function in a sibling module with a
//! test beside it. This module is the seam, and it is deliberately thin.

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Stdio};

/// Run a program to completion with its output on this process's streams.
///
/// # Errors
/// When the program cannot be spawned, or exits non-zero.
pub fn run<S>(program: &str, args: &[S], cwd: &Path) -> Result<(), String>
where
    S: AsRef<OsStr>,
{
    let status = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .status()
        .map_err(|error| format!("{program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited {}", status.code().unwrap_or(-1)))
    }
}

/// Run a program and take its stdout, with stderr left on this process's stream.
///
/// Trailing newlines are stripped, which is what `$(…)` did and what every caller wants.
///
/// # Errors
/// When the program cannot be spawned, exits non-zero, or writes output that is not UTF-8.
pub fn capture<S>(program: &str, args: &[S], cwd: &Path) -> Result<String, String>
where
    S: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .stderr(Stdio::inherit())
        .output()
        .map_err(|error| format!("{program}: {error}"))?;
    if !output.status.success() {
        return Err(format!("{program} exited {}", output.status.code().unwrap_or(-1)));
    }
    let text =
        String::from_utf8(output.stdout).map_err(|_| format!("{program} wrote output that is not UTF-8"))?;
    Ok(text.trim_end_matches('\n').to_owned())
}

/// Run a program and take its stdout, with stderr SWALLOWED and failure reported as `None`.
///
/// For the questions whose answer may legitimately be "there isn't one" — a repository with no tag
/// yet, a tag that does not exist.
pub fn ask<S>(program: &str, args: &[S], cwd: &Path) -> Option<String>
where
    S: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    Some(text.trim_end_matches('\n').to_owned())
}

/// True when a program is on `PATH`.
///
/// A preflight that names the missing tool costs a `which`; learning it from `xcodebuild`'s
/// failure ten minutes into a build costs the build.
#[must_use]
pub fn on_path(program: &str) -> bool {
    Command::new("/usr/bin/which")
        .arg(program)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// The `── … ──` banner every stage of a release prints, so a long log reads as steps.
pub fn step(what: &str) {
    println!("── {what} ──");
}
