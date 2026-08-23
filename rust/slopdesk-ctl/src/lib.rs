//! `slopdesk-ctl` — the reference client for the agent-control `AF_UNIX` socket.
//!
//! ## Why this is Rust
//! It is the CLI an agent forks per command — `read`, `wait`, `write`, `run` — so its cost is
//! process startup and nothing else. Measured on one machine, 400 runs each, against the fork/exec
//! floor of `/usr/bin/true` (2.28 ms median): the Swift build spent **3.47 ms** of its own above
//! that floor, this one spends **0.73 ms** — landing on the Rust hook next door, which spends 0.68.
//! Everything the binary actually does is one connect and one line of JSON.
//! (`docs/DECISIONS.md`, "uniffi-rs — evaluated on request", listed this port as planned for
//! exactly that reason; the entry after it records the port.)
//!
//! ## Shape
//! - [`args`] — global flags, pure.
//! - [`protocol`] — the request/response NDJSON and one builder per verb, pure.
//! - [`render`] — everything printed, pure.
//! - [`commands`] — one function per subcommand, over the [`commands::Control`] trait.
//! - [`client`] — the socket that implements that trait.
//! - [`usage`] — `--help`.
//!
//! The trait is the reason the whole CLI is testable: in the Swift original the subcommands called
//! `sendRequest` directly, so `main.swift` — every flag, every exit code, every rendered line — was
//! compiled-and-reviewed only, and the tests could reach nothing but the parameter builders.

pub mod args;
pub mod client;
pub mod commands;
pub mod protocol;
pub mod render;
pub mod usage;

use crate::args::{ParseError, parse_global};
use crate::commands::{Control, Ctx, Io, SocketControl};

/// The environment variable that names the control socket. The host injects it into every PTY it
/// spawns, so an agent running inside a pane needs no discovery at all.
pub const SOCKET_ENV: &str = "SLOPDESK_CONTROL_SOCKET";

/// The exit code for a bare invocation with no subcommand — usage went to stdout, but nothing ran.
pub const EXIT_USAGE: u8 = 2;

/// Everything the run needs from outside the process.
#[derive(Debug, Default, Clone)]
pub struct Environment {
    /// `SLOPDESK_CONTROL_SOCKET`, empty when unset.
    pub control_socket: String,
    /// `$HOME`, empty when unset.
    pub home: String,
    /// `$SHELL`, empty when unset.
    pub shell: String,
}

impl Environment {
    /// Reads the three variables the CLI cares about out of the real process environment.
    #[must_use]
    pub fn from_process() -> Self {
        let read = |key: &str| std::env::var(key).unwrap_or_default();
        Self {
            control_socket: read(SOCKET_ENV),
            home: read("HOME"),
            shell: read("SHELL"),
        }
    }
}

/// The basename of `argv[0]`, or `slopdesk-ctl` when there is nothing to take one from.
#[must_use]
pub fn program_name(argv0: Option<&str>) -> String {
    argv0
        .and_then(|path| path.rsplit('/').next())
        .filter(|name| !name.is_empty())
        .unwrap_or("slopdesk-ctl")
        .to_owned()
}

/// Picks the control socket: `--socket` first, then the environment.
///
/// # Errors
/// The message to print when neither names one — including the hint about where the variable
/// normally comes from, because "no socket" almost always means "not run from inside a pane".
pub fn resolve_socket_path(explicit: &str, env: &Environment, program: &str) -> Result<String, String> {
    if !explicit.is_empty() {
        return Ok(explicit.to_owned());
    }
    if !env.control_socket.is_empty() {
        return Ok(env.control_socket.clone());
    }
    Err(format!(
        "no control socket path: set {SOCKET_ENV} or pass --socket PATH\n{program}: hint: run from inside a \
         pane spawned by slopdesk-hostd with SLOPDESK_AGENT_CONTROL=1"
    ))
}

/// Routes a parsed subcommand to its implementation.
///
/// # Errors
/// Whatever the subcommand failed with — the message `main` prints as `<program>: <message>`.
pub fn dispatch(
    subcommand: &str,
    rest: &[String],
    ctl: &mut impl Control,
    io: &mut Io<'_>,
    ctx: &Ctx,
) -> Result<u8, String> {
    match subcommand {
        "list-panes" => commands::list_panes(ctl, rest, io, ctx),
        "read" => commands::read(ctl, rest, io),
        "screen" => commands::screen(ctl, rest, io),
        "last-output" => commands::last_output(ctl, rest, io),
        "write" => commands::write(ctl, rest),
        "run" => commands::run(ctl, rest, io, ctx),
        "wait" => commands::wait(ctl, rest, io, ctx),
        "spawn" => commands::spawn(ctl, rest, io, ctx),
        "kill" => commands::kill(ctl, rest, io),
        "subscribe" => commands::subscribe(ctl, rest, io),
        "events" => commands::events(ctl, rest, io),
        "report" => commands::report(ctl, rest, io),
        "resize" => commands::resize(ctl, rest, io),
        other => Err(format!("unknown subcommand '{other}' (run with --help)")),
    }
}

/// The whole program, minus the process: parse, resolve, dispatch, and hand back an exit code.
///
/// # Errors
/// Any message that should be printed as `<program>: <message>` before exiting 1.
pub fn run(argv: &[String], env: &Environment, io: &mut Io<'_>) -> Result<u8, String> {
    let program = program_name(argv.first().map(String::as_str));

    // BEFORE `parse_global`, which would reject `--version` as an unknown flag — and ahead of the
    // socket resolution for the reason the help branch below is: a version question must be
    // answerable by a binary that cannot reach a host, because "which one is installed" is exactly
    // what someone asks when nothing is answering.
    //
    // The SECOND whitespace-separated field of the FIRST line is the version, which is the shape
    // every tool in this tree answers and the one `slopdesk-release package` parses when it checks a
    // built binary against `scripts/tool-stamps.pin`.
    if argv.get(1).is_some_and(|argument| argument == "--version") {
        io.out
            .write_all(format!("slopdesk-ctl {}\n", env!("CARGO_PKG_VERSION")).as_bytes())
            .map_err(|err| format!("write failed: {err}"))?;
        return Ok(0);
    }

    let global = parse_global(argv).map_err(|err| {
        match err {
            ParseError::UnknownFlag(flag) => format!("unknown flag '{flag}' (run with --help)"),
            ParseError::MissingValue(flag) => format!("'{flag}' requires a value"),
        }
    })?;

    if global.subcommand.is_empty() || global.subcommand == "help" {
        io.out
            .write_all(usage::usage(&program).as_bytes())
            .map_err(|err| format!("write failed: {err}"))?;
        // An explicit `--help` is a success; a bare invocation is a usage error that happens to
        // print the same text.
        return Ok(if global.subcommand == "help" {
            0
        } else {
            EXIT_USAGE
        });
    }

    let socket_path = resolve_socket_path(&global.socket_path, env, &program)?;
    let ctx = Ctx {
        home: env.home.clone(),
        shell: env.shell.clone(),
        program,
    };
    let mut ctl = SocketControl { socket_path };
    dispatch(&global.subcommand, &global.rest, &mut ctl, io, &ctx)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{EXIT_USAGE, Environment, Io, SOCKET_ENV, program_name, resolve_socket_path, run};

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    fn capture(args: &[&str], env: &Environment) -> (Result<u8, String>, String) {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = {
            let mut io = Io {
                out: &mut out,
                err: &mut err,
            };
            run(&argv(args), env, &mut io)
        };
        (code, String::from_utf8(out).expect("stdout is UTF-8"))
    }

    #[test]
    fn version_answers_without_a_socket_and_puts_the_number_in_the_second_field() {
        // A default `Environment` names no control socket, so a run that reached
        // `resolve_socket_path` would fail — which is the point: `--version` is what someone types
        // when nothing is answering.
        let (code, text) = capture(&["slopdesk-ctl", "--version"], &Environment::default());
        assert_eq!(code, Ok(0));

        let first_line = text.lines().next().expect("a first line");
        let mut fields = first_line.split_whitespace();
        assert_eq!(fields.next(), Some("slopdesk-ctl"));
        // The contract `slopdesk-release package` parses, and the reason this asserts on a FIELD
        // than on the whole string: the banner may grow, the position of the version may not.
        assert_eq!(fields.next(), Some(env!("CARGO_PKG_VERSION")));
    }

    #[test]
    fn the_program_name_is_the_basename_however_it_was_invoked() {
        assert_eq!(program_name(Some("/usr/local/bin/slopdesk-ctl")), "slopdesk-ctl");
        assert_eq!(program_name(Some("slopdesk-ctl")), "slopdesk-ctl");
        assert_eq!(program_name(Some("./ctl2")), "ctl2");
        // A trailing slash leaves no name; so does no argv at all.
        assert_eq!(program_name(Some("/usr/bin/")), "slopdesk-ctl");
        assert_eq!(program_name(None), "slopdesk-ctl");
    }

    #[test]
    fn the_socket_flag_outranks_the_environment_and_the_environment_outranks_nothing() {
        let env = Environment {
            control_socket: "/tmp/env.sock".to_owned(),
            ..Environment::default()
        };
        assert_eq!(
            resolve_socket_path("/tmp/flag.sock", &env, "p"),
            Ok("/tmp/flag.sock".to_owned())
        );
        assert_eq!(resolve_socket_path("", &env, "p"), Ok("/tmp/env.sock".to_owned()));

        let err = resolve_socket_path("", &Environment::default(), "slopdesk-ctl")
            .expect_err("nothing names a socket");
        assert!(
            err.contains(SOCKET_ENV),
            "the message names the variable to set: {err}"
        );
        assert!(err.contains("hint: run from inside a pane"), "{err}");
    }

    #[test]
    fn explicit_help_exits_zero_and_a_bare_invocation_exits_two_with_the_same_text() {
        let env = Environment::default();
        let (code, text) = capture(&["slopdesk-ctl", "--help"], &env);
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("usage: slopdesk-ctl"));

        let (code, bare) = capture(&["slopdesk-ctl"], &env);
        assert_eq!(code, Ok(EXIT_USAGE));
        assert_eq!(bare, text, "both print usage; only the exit code separates them");
    }

    #[test]
    fn help_never_needs_a_socket_so_it_works_outside_a_pane() {
        // The resolve step sits AFTER the help branch on purpose: `--help` is what you run when you
        // do not yet know how to point the CLI at a host.
        let (code, _) = capture(&["slopdesk-ctl", "--help"], &Environment::default());
        assert_eq!(code, Ok(0));
    }

    #[test]
    fn an_unknown_subcommand_is_refused_before_any_socket_work() {
        let env = Environment {
            control_socket: "/tmp/nope.sock".to_owned(),
            ..Environment::default()
        };
        let (code, _) = capture(&["slopdesk-ctl", "frobnicate"], &env);
        assert_eq!(
            code,
            Err("unknown subcommand 'frobnicate' (run with --help)".to_owned())
        );
    }

    #[test]
    fn an_unknown_global_flag_is_refused_by_name() {
        let (code, _) = capture(&["slopdesk-ctl", "--bogus"], &Environment::default());
        assert_eq!(code, Err("unknown flag '--bogus' (run with --help)".to_owned()));
    }

    #[test]
    fn a_dangling_socket_flag_is_refused_by_name() {
        let (code, _) = capture(&["slopdesk-ctl", "--socket"], &Environment::default());
        assert_eq!(code, Err("'--socket' requires a value".to_owned()));
    }

    #[test]
    fn a_real_subcommand_with_no_socket_anywhere_says_so_rather_than_dialling_nothing() {
        let (code, _) = capture(&["slopdesk-ctl", "list-panes"], &Environment::default());
        let err = code.expect_err("there is no socket to reach");
        assert!(err.starts_with("no control socket path:"), "{err}");
    }
}
