//! One subcommand per metadata query, one answer on stdout.
//!
//! ## Two output shapes, on purpose
//! Four subcommands print one JSON object. Two — `git-diff` and `read-session` — print RAW BYTES,
//! because their answer IS bytes: a patch or a transcript, up to 15 MiB of it, that hostd forwards
//! into an opaque wire payload without looking inside. Wrapping those in JSON would mean escaping
//! every byte on the way out and unescaping it on the way in, to move a blob neither side reads.
//!
//! Which leaves the raw pair needing a way to say "nothing there", since empty bytes are a
//! legitimate answer (a file with no diff) and distinct from a missing one (a path that does not
//! resolve). That is the exit code:
//!
//! ```text
//! 0  → the answer is on stdout (possibly empty)
//! 3  → not found — the verb's `.notFound`, distinct from an empty answer
//! 2  → the arguments were unusable, which is a bug in the caller
//! ```
//!
//! ```text
//! git-diff      --cwd P --file F       → raw patch bytes
//! list-dir      --path P               → {"entries":[{"isDir":…,"name":…}]}
//! list-sessions --project P            → {"sessions":[{"kind":…,"id":…,"title":…,"cwd":…,"mtimeMS":…}]}
//! read-session  --id P                 → raw transcript bytes
//! terminfo      --requested T --fallback F → {"term":…,"fellBack":…}
//! ```

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::Path;
use std::process::ExitCode;

use slopdesk_probe::{files, git, terminfo};

/// The exit code for a query whose subject does not exist.
const NOT_FOUND: u8 = 3;
/// The exit code for arguments this program cannot act on.
const BAD_ARGUMENTS: u8 = 2;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(subcommand) = arguments.first() else {
        return usage();
    };
    if subcommand == "--version" {
        return print_version();
    }
    let Some(flags) = parse_flags(arguments.get(1..).unwrap_or_default()) else {
        return usage();
    };
    let flag = |name: &str| flags.get(name).cloned();
    let home = std::env::var("HOME").unwrap_or_default();

    match subcommand.as_str() {
        "git-diff" => {
            match (flag("--cwd"), flag("--file")) {
                (Some(cwd), Some(file)) => print_bytes(git::diff(&cwd, &file)),
                _ => usage(),
            }
        },
        "list-dir" => {
            flag("--path").map_or_else(usage, |path| {
                files::list_directory(Path::new(&path))
                    .map_or_else(not_found, |entries| print_json(&files::directory_json(&entries)))
            })
        },
        "list-sessions" => {
            flag("--project").map_or_else(usage, |project| {
                print_json(&files::sessions_json(&files::list_sessions(&home, &project)))
            })
        },
        "read-session" => flag("--id").map_or_else(usage, |id| print_bytes(files::read_session(&home, &id))),
        "terminfo" => {
            match (flag("--requested"), flag("--fallback")) {
                (Some(requested), Some(fallback)) => {
                    let (term, fell_back) =
                        terminfo::resolve(&requested, &fallback, &terminfo::process_environment());
                    print_json(&terminfo::to_json(&term, fell_back))
                },
                _ => usage(),
            }
        },
        _ => usage(),
    }
}

/// `--name value` pairs. `None` for an odd tail or a bare word, both of which mean the caller built
/// the argv wrong — and a probe that guessed at a half-given path is a probe that reads the wrong
/// directory.
fn parse_flags(arguments: &[String]) -> Option<BTreeMap<String, String>> {
    let mut flags = BTreeMap::new();
    let mut rest = arguments.iter();
    while let Some(name) = rest.next() {
        if !name.starts_with("--") {
            return None;
        }
        flags.insert(name.clone(), rest.next()?.clone());
    }
    Some(flags)
}

/// Writes one JSON object and a newline.
///
/// Through an explicit handle rather than `println!`: this crate shares the root workspace's ban on
/// the print macros, which is there for the hook relay's sake, and an escape hatch that is visible
/// at the call site is better than an allow that covers a whole file.
fn print_json(value: &serde_json::Value) -> ExitCode {
    let mut out = std::io::stdout().lock();
    let _unused = writeln!(out, "{value}");
    ExitCode::SUCCESS
}

/// Writes an opaque answer, or reports it missing.
fn print_bytes(answer: Option<Vec<u8>>) -> ExitCode {
    let Some(bytes) = answer else {
        return not_found();
    };
    let mut out = std::io::stdout().lock();
    let _unused = out.write_all(&bytes);
    let _unused = out.flush();
    ExitCode::SUCCESS
}

/// The subject does not exist — distinct from an empty answer, which exits 0 with nothing.
fn not_found() -> ExitCode {
    ExitCode::from(NOT_FOUND)
}

/// `--version`, on STDOUT — the one thing this program prints there that is not a query answer.
///
/// The usage text below goes to stderr because two subcommands stream opaque bytes; a version
/// banner is different in the way that matters, because nobody pipes `--version` into a patch. It
/// is asked interactively, and an interactive answer belongs on stdout.
///
/// Through an explicit handle rather than `println!`, for the reason [`print_json`] gives: this
/// crate shares the root workspace's ban on the print macros for the hook relay's sake, and one
/// more exemption is one more thing to reason about.
///
/// The SECOND whitespace-separated field of the FIRST line is the version, which is the shape
/// every tool in this tree answers and the one `slopdesk-release package` parses when it checks a
/// built binary against `scripts/tool-stamps.pin`.
fn print_version() -> ExitCode {
    let mut out = std::io::stdout().lock();
    let _unused = writeln!(out, "slopdesk-probe {}", env!("CARGO_PKG_VERSION"));
    ExitCode::SUCCESS
}

/// The usage text, on stderr: stdout carries opaque bytes for two of these subcommands, and a
/// caller piping a patch to a file must never find a usage line in the middle of it.
fn usage() -> ExitCode {
    let mut err = std::io::stderr().lock();
    let _unused = writeln!(
        err,
        "usage: slopdesk-probe <git-status --cwd P | git-diff --cwd P --file F | list-dir --path P | \
         list-sessions --project P | read-session --id P | terminfo --requested T --fallback F>"
    );
    ExitCode::from(BAD_ARGUMENTS)
}
