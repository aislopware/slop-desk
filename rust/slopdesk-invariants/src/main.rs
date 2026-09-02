//! The gate, as a command.
//!
//! ```text
//! slopdesk-invariants [--root DIR] [--only SUBSTRING] [--list] [--compare-shell SCRIPT]
//! ```
//!
//! Exit 0 when every rule passes, 1 when any fails, 2 when the tree could not be read — the same
//! three outcomes the shell had, so the justfile target does not learn anything new.
//!
//! ## `--compare-shell`, and why it is in the binary rather than in a test
//! Each section is deleted from the shell in the commit that ports it, which is the only way a
//! reader can ever be sure there is one implementation. The risk that buys is a wrong port that
//! silently stops enforcing something — green here, green there, nothing checked. `--compare-shell`
//! runs the named script, parses its `check-…: FAIL — ` lines, and diffs the violation set against
//! this crate's. On a clean tree both are empty and it proves nothing; run against a tree with a
//! seeded breakage, it proves the two agree about that breakage. It is a porting instrument, not a
//! gate, and it is expected to disappear with the last shell section.

// The gate's report IS its standard streams: violations and the read failure on stderr, where the
// shell wrote them and the justfile reads them, and the `--list` and `--compare-shell` tables on
// stdout.
#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a gate's verdict is its standard streams"
)]

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_invariants::{Tree, all_rules, run};

fn main() -> ExitCode {
    let mut root: Option<PathBuf> = None;
    let mut only: Option<String> = None;
    let mut compare: Option<String> = None;
    let mut list = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--only" => only = args.next(),
            "--compare-shell" => compare = args.next(),
            "--list" => list = true,
            "-h" | "--help" => {
                println!(
                    "slopdesk-invariants [--root DIR] [--only SUBSTRING] [--list] [--compare-shell SCRIPT]",
                );
                return ExitCode::SUCCESS;
            },
            other => {
                eprintln!("slopdesk-invariants: unknown argument {other}");
                return ExitCode::from(2);
            },
        }
    }

    if list {
        for rule in all_rules() {
            println!("{:<32} {}", rule.name, rule.origin);
        }
        return ExitCode::SUCCESS;
    }

    let root = root.unwrap_or_else(|| {
        // Two levels above this crate is the repository, which is where `just` runs it from anyway.
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    });
    let tree = match Tree::load(&root) {
        Ok(tree) => tree,
        Err(err) => {
            eprintln!("slopdesk-invariants: cannot read {}: {err}", root.display());
            return ExitCode::from(2);
        },
    };

    let violations = run(&tree, only.as_deref());

    if let Some(script) = compare {
        return compare_shell(&root, &script, &violations);
    }

    for violation in &violations {
        eprintln!("slopdesk-invariants: FAIL — {violation}");
    }
    if violations.is_empty() {
        ExitCode::SUCCESS
    } else {
        eprintln!("slopdesk-invariants: {} violation(s)", violations.len());
        ExitCode::FAILURE
    }
}

/// Runs the shell gate and reports where the two disagree about the SAME tree.
///
/// The comparison is by count and by presence of the distinguishing words, not by string equality:
/// the two print the same diagnostics but this crate prefixes each with its rule name, and the
/// shell interleaves its own progress lines. What matters is that neither side is silent where the
/// other speaks.
fn compare_shell(root: &std::path::Path, script: &str, ours: &[String]) -> ExitCode {
    let output = match std::process::Command::new("bash")
        .arg(script)
        .current_dir(root)
        .output()
    {
        Ok(output) => output,
        Err(err) => {
            eprintln!("slopdesk-invariants: cannot run {script}: {err}");
            return ExitCode::from(2);
        },
    };
    let stderr = String::from_utf8_lossy(&output.stderr);
    let theirs: Vec<&str> = stderr
        .lines()
        .filter_map(|line| line.split_once("FAIL — ").map(|(_, rest)| rest))
        .collect();

    println!("rust : {} violation(s)", ours.len());
    for violation in ours {
        println!("  + {violation}");
    }
    println!("shell: {} violation(s)", theirs.len());
    for violation in &theirs {
        println!("  - {violation}");
    }

    // Agreement is "both silent" or "both speak". A port that under-checks shows up as the shell
    // speaking alone, which is the only direction that is a bug rather than a scope difference:
    // this crate also enforces rules the shell never had.
    if theirs.is_empty() || !ours.is_empty() {
        println!("agree: neither side is silent where the other speaks");
        ExitCode::SUCCESS
    } else {
        println!("DISAGREE: the shell found violations this crate did not");
        ExitCode::FAILURE
    }
}
