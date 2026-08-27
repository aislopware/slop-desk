//! `slopdesk-provision` — the command.
//!
//! ```text
//! slopdesk-provision                 # provision everything in tools.lock
//! slopdesk-provision code-server     # just one entry
//! slopdesk-provision --check         # verify what is installed; download nothing
//! ```
//!
//! Exit codes are the shell's, verbatim, because `just provision-check` reads them: `0` all
//! present, `1` something is missing or a digest did not match, `2` the arguments were wrong.

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_provision::plan::Layout;
use slopdesk_provision::{Mode, Tally, run};

/// The argument grammar, parsed.
struct Invocation {
    mode: Mode,
    wanted: Vec<String>,
}

fn main() -> ExitCode {
    let Some(invocation) = parse(std::env::args().skip(1)) else {
        return ExitCode::from(2);
    };
    let layout = Layout::new(tools_dir());
    match run(&layout, invocation.mode, &invocation.wanted) {
        Ok(tally) => report(&layout, invocation.mode, tally),
        Err(failure) => {
            eprintln!("ERROR: {failure}");
            ExitCode::FAILURE
        },
    }
}

/// `--check` plus any number of pin names. An unknown flag is a usage error rather than a name.
fn parse(args: impl Iterator<Item = String>) -> Option<Invocation> {
    let mut mode = Mode::Provision;
    let mut wanted = Vec::new();
    for arg in args {
        match arg.as_str() {
            "--check" => mode = Mode::Check,
            flag if flag.starts_with('-') => {
                eprintln!("unknown flag: {flag}");
                return None;
            },
            name => wanted.push(name.to_owned()),
        }
    }
    Some(Invocation { mode, wanted })
}

/// The closing summary, and the exit code that goes with it.
fn report(layout: &Layout, mode: Mode, tally: Tally) -> ExitCode {
    println!();
    match mode {
        Mode::Check => {
            println!("checked: {} present, {} missing", tally.current, tally.missing);
            if tally.missing == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        },
        Mode::Provision => {
            println!(
                "provisioned: {} installed, {} already current",
                tally.installed, tally.current
            );
            println!("prefix: {}", layout.prefix().display());
            ExitCode::SUCCESS
        },
    }
}

/// `ThirdParty/tools`, found the way the shell found it: relative to this program rather than to
/// the caller's working directory.
///
/// `SLOPDESK_TOOLS_DIR` overrides it, which is what lets the gate point a run at a scratch tree —
/// the shell had no such seam, and adding it is why the layout is a value rather than four
/// `const`s.
fn tools_dir() -> PathBuf {
    if let Some(override_path) = std::env::var_os("SLOPDESK_TOOLS_DIR") {
        return PathBuf::from(override_path);
    }
    // `CARGO_MANIFEST_DIR` is `rust/slopdesk-provision`; the tools tree is two levels up and across.
    // Resolved at COMPILE time on purpose: this binary is run by `just provision` out of the tree it
    // was built in, and a runtime walk from `current_exe()` would have to guess past `target/`.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../ThirdParty/tools")
        .components()
        .collect()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_provision::Mode;

    use super::parse;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter()
            .map(|arg| (*arg).to_owned())
            .collect::<Vec<_>>()
            .into_iter()
    }

    #[test]
    fn no_arguments_provisions_everything() {
        let parsed = parse(args(&[])).expect("valid");
        assert_eq!(parsed.mode, Mode::Provision);
        assert!(parsed.wanted.is_empty());
    }

    #[test]
    fn names_narrow_the_run_and_check_disarms_it() {
        let parsed = parse(args(&["--check", "adb", "code-server"])).expect("valid");
        assert_eq!(parsed.mode, Mode::Check);
        assert_eq!(parsed.wanted, ["adb", "code-server"]);
    }

    #[test]
    fn an_unknown_flag_is_a_usage_error_not_a_pin_name() {
        assert!(parse(args(&["--force"])).is_none());
        assert!(parse(args(&["-x"])).is_none());
    }

    /// The tools directory resolves to a real `tools.lock`, which is the one thing a wrong relative
    /// path would silently get away with until someone ran a provision.
    #[test]
    fn the_tools_directory_holds_the_lock() {
        assert!(super::tools_dir().join("tools.lock").is_file());
    }
}
