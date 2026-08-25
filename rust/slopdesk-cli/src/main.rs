//! Thin process adapter around [`slopdesk_cli::shell::run`]. Every decision lives in the library so
//! it is reachable from a test without a process boundary; this file only wires the real argv, the
//! real environment and the real stdio in, and turns the outcome into an exit status.
//!
//! This is the whole of what the deleted `main.swift` of the `Sources/slopdesk` target used to be
//! that a test could not enter.

use std::io::Write;
use std::process::ExitCode;

use slopdesk_cli::shell::{Environment, Io, program_name, run};

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();

    // stdout is locked once and buffered: a `pane capture` answer is a screen's worth of
    // scrollback, and the unbuffered per-write the Swift used turned that into one syscall per
    // line. `watch` flushes explicitly around the subprocess it spawns, which is the one place the
    // buffering would otherwise reorder bytes against a child that inherits this same descriptor.
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    let stderr = std::io::stderr();
    let mut err = stderr.lock();

    let outcome = {
        let mut io = Io {
            out: &mut out,
            err: &mut err,
        };
        run(&argv, &Environment::from_process(), &mut io)
    };

    // Flush BEFORE the exit code is chosen: a buffered write that fails at drop time would
    // otherwise report success for output nobody received.
    if let Err(flush) = out.flush() {
        diagnose(&mut err, &argv, &format!("write to stdout failed: {flush}"));
        return ExitCode::from(1);
    }

    match outcome {
        Ok(code) => ExitCode::from(code),
        Err(failure) => {
            diagnose(&mut err, &argv, &failure.message);
            ExitCode::from(failure.code)
        },
    }
}

/// Prints `<program>: <message>` on stderr, ignoring a failure — if stderr itself is gone there is
/// nothing left to report the failure ON, and the exit code still carries the outcome.
fn diagnose(sink: &mut impl Write, argv: &[String], message: &str) {
    let program = program_name(argv.first().map(String::as_str));
    drop(writeln!(sink, "{program}: {message}"));
}
