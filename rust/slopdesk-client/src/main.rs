//! Thin process adapter around [`slopdesk_client::relay::run`]. Real argv, real stderr, and the
//! outcome as an exit status — nothing else, so every decision stays where a test can reach it.
//!
//! `main` RETURNS its code rather than calling `exit`, and that is load-bearing rather than
//! stylistic: the raw-mode guard puts the terminal back in its `Drop`, and `exit(3)` runs no
//! destructors. The Swift called `exit` from inside a closure and needed a hand-written `Shutdown`
//! type to sequence the restore ahead of it.

use std::io::Write;
use std::process::ExitCode;

use slopdesk_client::args::{ArgsError, USAGE_BODY, parse, program_name};
use slopdesk_client::relay::run;

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    let stderr = std::io::stderr();
    let mut errors = stderr.lock();
    let program = program_name(argv.first().map(String::as_str));

    match parse(&argv) {
        Ok(parsed) => ExitCode::from(run(&parsed, &mut errors)),
        // `--help` and a usage error print the SAME block and differ only in the code: a user who
        // asked for help got what they asked for, and one who mistyped a flag did not.
        Err(failure) => {
            if failure == ArgsError::HelpRequested {
                usage(&mut errors, program);
                return ExitCode::SUCCESS;
            }
            drop(writeln!(errors, "{program}: {failure}"));
            usage(&mut errors, program);
            ExitCode::from(2)
        },
    }
}

/// Prints the usage block on stderr, ignoring a failure — stdout is reserved for the session's
/// bytes even on the path where there is no session.
fn usage(sink: &mut impl Write, program: &str) {
    drop(writeln!(
        sink,
        "usage: {program} --host <h> --port <n> [--no-raw] [--session-id <uuid>]\n\n{USAGE_BODY}"
    ));
}
