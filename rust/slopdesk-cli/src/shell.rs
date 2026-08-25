//! The process the pure core sits inside: the environment it reads, the sinks it writes, the
//! failure it can end with, and the dispatch from a parsed invocation to one subcommand.
//!
//! Everything here used to be the `Sources/slopdesk` target's `main.swift` — a thousand lines no
//! test could reach, because every one of them ended in `exit()`. The rule that kept it that way
//! was a real one ("a CLI's socket half is compiled-and-reviewed, so keep the reviewable part
//! small"), and the way out of it is the one `slopdesk-ctl` took next door: the subcommands talk to
//! the app through the [`Control`] trait rather than a socket, and hand back an exit code instead
//! of taking one. A test can then drive a whole subcommand — its flags, its rendering and the
//! status it would give the shell — against a canned response.
//!
//! [`main`](../../main/index.html) is the only thing left that a test cannot enter, and all it does
//! is wire the real argv, the real environment and the real stdio in.

pub mod commands;
pub mod config;
pub mod local;
pub mod socket;
pub mod watch;

use std::collections::BTreeMap;
use std::io::Write;

use crate::args::{Invocation, ParseError, parse};
use crate::clientctl::Params;
use crate::{version, vocabulary};

/// The environment variable the running app exports and the CLI reads, naming the control socket.
pub const SOCKET_ENV: &str = "SLOPDESK_CLIENT_SOCKET";

/// The exit code for a usage error — a flag that does not exist, a value that does not parse, a
/// verb that is designed but not built.
pub const EXIT_USAGE: u8 = 2;

/// The exit code for "there is no running app to ask".
///
/// Distinct from a plain failure because it is the one a script branches on: every app-driving verb
/// answers it identically, and it means "start `SlopDesk`", never "your arguments were wrong".
pub const EXIT_NO_APP: u8 = 3;

/// How a run ended badly: the message to print, and the status to hand the shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// The exit status.
    pub code: u8,
    /// The sentence, printed as `<program>: <message>`.
    pub message: String,
}

impl Failure {
    /// A failure with an explicit code.
    #[must_use]
    pub fn new(code: u8, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// A plain failure — exit 1. The app refused, a file could not be written, a font could not be
    /// installed.
    #[must_use]
    pub fn plain(message: impl Into<String>) -> Self {
        Self::new(1, message)
    }

    /// A usage error — exit 2.
    #[must_use]
    pub fn usage(message: impl Into<String>) -> Self {
        Self::new(EXIT_USAGE, message)
    }

    /// A transport failure — exit 3, "requires a running app".
    #[must_use]
    pub fn no_app(message: impl Into<String>) -> Self {
        Self::new(EXIT_NO_APP, message)
    }
}

/// What a subcommand hands back: an exit code, or the failure to print before exiting.
pub type Run = Result<u8, Failure>;

/// The far end, as the subcommands need it.
///
/// The reason the whole CLI is testable: in the Swift original every subcommand called
/// `clientSendRequest` directly, so the flag parsing, the exit codes and the rendered lines were
/// all downstream of a real socket.
pub trait Control {
    /// Sends one request and returns the decoded `result` object of an `ok:true` response.
    ///
    /// # Errors
    /// Any transport failure, a malformed response, or an `ok:false` the app answered with.
    fn call(&mut self, method: &str, params: Params) -> Result<Params, Failure>;
}

/// The two output sinks, so a test can read what a subcommand printed.
pub struct Io<'a> {
    /// Everything the caller is meant to consume.
    pub out: &'a mut dyn Write,
    /// Status lines and diagnostics.
    pub err: &'a mut dyn Write,
}

// `dyn Write` is not `Debug`, so this is written out rather than derived. It names the sinks
// without touching them — formatting a sink would be a side effect inside a `Debug` impl.
impl std::fmt::Debug for Io<'_> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Io { out, err }")
    }
}

/// The process environment, captured once.
///
/// Injected rather than read at each use, so every resolution order below is testable without
/// mutating a real process env.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Environment {
    vars: BTreeMap<String, String>,
}

impl Environment {
    /// Every variable this process was started with.
    #[must_use]
    pub fn from_process() -> Self {
        Self {
            vars: std::env::vars().collect(),
        }
    }

    /// An environment built from pairs, for a test.
    #[must_use]
    pub fn from_pairs(pairs: &[(&str, &str)]) -> Self {
        Self {
            vars: pairs
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
        }
    }

    /// The value of `key`, treating empty as unset.
    ///
    /// The shell idiom `FOO="${BAR}"` with `BAR` unset is the usual way one of these arrives empty,
    /// and an empty path is never what the writer meant.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<&str> {
        self.vars
            .get(key)
            .map(String::as_str)
            .filter(|value| !value.is_empty())
    }

    /// `$HOME`, or `/` when nothing names one — every path built on it is then obviously wrong
    /// rather than quietly relative.
    #[must_use]
    pub fn home(&self) -> &str {
        self.get("HOME").unwrap_or("/")
    }
}

/// Everything a subcommand reads that is neither a flag nor an answer.
#[derive(Debug, Clone)]
pub struct Ctx {
    /// The parsed global flags.
    pub invocation: Invocation,
    /// The captured environment.
    pub environment: Environment,
    /// `argv[0]`'s basename, for the messages that name the program.
    pub program: String,
}

/// The basename of `argv[0]`, or `slopdesk` when there is nothing to take one from.
#[must_use]
pub fn program_name(argv0: Option<&str>) -> String {
    argv0
        .and_then(|path| path.rsplit('/').next())
        .filter(|name| !name.is_empty())
        .unwrap_or("slopdesk")
        .to_owned()
}

/// Writes `text` to a sink, turning a broken pipe into a failure rather than a panic.
///
/// # Errors
/// Any write failure.
pub fn print(sink: &mut dyn Write, text: &str) -> Result<(), Failure> {
    sink.write_all(text.as_bytes())
        .map_err(|error| Failure::plain(format!("write failed: {error}")))
}

/// Routes a parsed subcommand to its implementation.
///
/// The match arms are held to `vocabulary::SUBCOMMANDS` by a test in this module: a verb the table
/// calls `Ready` with no arm here is a completion that exits 2 — the reported bug the table was
/// written for — and an arm for a verb the table does not call `Ready` is a command that works and
/// that no shell will ever offer.
///
/// # Errors
/// Whatever the subcommand failed with.
pub fn dispatch(ctl: &mut impl Control, io: &mut Io<'_>, ctx: &Ctx) -> Run {
    let rest = &ctx.invocation.rest;
    match ctx.invocation.subcommand.as_str() {
        // Local ops — no running app.
        "version" => local::version(io, ctx),
        "completions" => local::completions(io, rest),
        "sidecars" => local::sidecars(io, rest, ctx),
        "config" => config::config(io, rest, ctx),
        // App-driving list shortcuts (plural ≡ `<noun> list`).
        "windows" => commands::window_list(ctl, io, rest, ctx),
        "tabs" => commands::tab_list(ctl, io, rest, ctx),
        "panes" => commands::pane_list(ctl, io, rest, ctx),
        // App-driving nouns.
        "window" => commands::window(ctl, io, rest, ctx),
        "tab" => commands::tab(ctl, io, rest, ctx),
        "pane" => commands::pane(ctl, io, rest, ctx),
        "font" => local::font(ctl, io, rest, ctx),
        "keybind" => commands::keybind(ctl, io, rest, ctx),
        "jump" => commands::jump(ctl, io, rest, ctx),
        "learn" => commands::learn(ctl, io, rest, ctx),
        "ignore" => commands::ignore(ctl, rest),
        "view" => commands::view(ctl, rest),
        "edit" => commands::edit(ctl, rest),
        // In-pane op — no client socket at all.
        "watch" => watch::watch(io, rest, ctx),
        // App-driving: block until a Claude session reaches idle/closed.
        "watch:claude" => watch::watch_claude(ctl, rest, &watch::MonotonicClock),
        other => Err(unknown_subcommand(other)),
    }
}

/// The two different failures a verb nobody dispatches can be, which conflating is what made the
/// drift invisible.
///
/// A verb the vocabulary lists as PLANNED is real, designed and not built; a verb it does not list
/// at all is a typo. Neither is offered for completion, so neither can be reached by pressing Tab.
fn unknown_subcommand(verb: &str) -> Failure {
    if vocabulary::planned_names().contains(&verb) {
        return Failure::usage(format!(
            "subcommand '{verb}' is designed but not implemented yet (run with --help — it is listed there \
             under \"NOT yet implemented\")"
        ));
    }
    Failure::usage(format!("unknown subcommand '{verb}' (run with --help)"))
}

/// The whole program, minus the process: parse, decide, dispatch, and hand back an exit code.
///
/// # Errors
/// Any message that should be printed as `<program>: <message>` before exiting with its code.
pub fn run(argv: &[String], environment: &Environment, io: &mut Io<'_>) -> Run {
    let program = program_name(argv.first().map(String::as_str));
    let invocation = parse(argv).map_err(|error| {
        match error {
            ParseError::UnknownFlag(flag) => {
                Failure::usage(format!("unknown flag '{flag}' (run with --help)"))
            },
            ParseError::MissingValue(flag) => Failure::usage(format!("'{flag}' requires a value")),
            ParseError::InvalidValue { flag, value } => {
                Failure::usage(format!("invalid value '{value}' for {flag}"))
            },
        }
    })?;

    // Help wins over everything, including the GUI launch: `--help` is what somebody types when
    // they do not want a window.
    if invocation.wants_help || invocation.subcommand == "help" {
        print(io.out, &vocabulary::usage(&program))?;
        return Ok(0);
    }

    let ctx = Ctx {
        invocation,
        environment: environment.clone(),
        program,
    };

    // A bare invocation (or `-e <cmd>`) launches the GUI the way bare xterm/alacritty/ghostty do.
    if ctx.invocation.launch_gui {
        return local::launch_gui(&ctx);
    }

    let mut ctl = socket::SocketControl::new(&ctx);
    dispatch(&mut ctl, io, &ctx)
}

/// Everything a subcommand needs of the version, in one place, so `version.rs` stays a pure
/// formatter.
///
/// The NUMBER is `CARGO_PKG_VERSION` — this crate's own `[package] version`, which is one of the
/// six sites `slopdesk-release bump-product` writes and verifies. It used to be a Swift constant in
/// `CLIVersion.swift`; moving it here did not add a seventh site, it MOVED one, which is why
/// `version.rs` still refuses to hold a constant of its own.
#[must_use]
pub fn version_summary(environment: &Environment) -> String {
    version::summary(
        env!("CARGO_PKG_VERSION"),
        environment.get(version::BUILD_HASH_ENV_KEY),
        slopdesk_wire::PROTOCOL_VERSION,
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::collections::BTreeSet;

    use super::{
        EXIT_USAGE, Environment, Failure, Io, program_name, run, unknown_subcommand, version_summary,
    };
    use crate::vocabulary::{self, Availability, SUBCOMMANDS};

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    fn capture(args: &[&str], environment: &Environment) -> (super::Run, String) {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = {
            let mut io = Io {
                out: &mut out,
                err: &mut err,
            };
            run(&argv(args), environment, &mut io)
        };
        (code, String::from_utf8(out).expect("stdout is UTF-8"))
    }

    /// THE ONE THAT REPLACES THE CROSS-LANGUAGE RULE. While the dispatch switch was Swift and the
    /// table was Rust, `slopdesk-invariants` had to read both files as TEXT to hold them together.
    /// Both are this crate's now, so the comparison is a test — and a test is stricter, because it
    /// reads the match arms the compiler compiled rather than the ones a regex could find.
    #[test]
    fn the_dispatch_switch_covers_exactly_the_verbs_the_shells_offer() {
        // Read out of THIS file's `dispatch`, which is the only place the arms exist.
        let source = include_str!("shell.rs");
        let arms: BTreeSet<&str> = source
            .lines()
            .filter_map(|line| line.trim().strip_prefix('"'))
            .filter_map(|rest| rest.split_once("\" =>"))
            .map(|(verb, _)| verb)
            .collect();
        assert!(arms.len() > 10, "the arm extraction went stale: {arms:?}");

        let ready: BTreeSet<&str> = SUBCOMMANDS
            .iter()
            .filter(|sub| sub.availability == Availability::Ready)
            .map(|sub| sub.name)
            // `help` is handled ABOVE the dispatch, because it has to win over the GUI launch.
            .filter(|name| *name != "help")
            .collect();

        let undispatched: Vec<&&str> = ready.difference(&arms).collect();
        assert!(
            undispatched.is_empty(),
            "Ready in the vocabulary with no arm — a completion that exits 2: {undispatched:?}"
        );
        let unlisted: Vec<&&str> = arms.difference(&ready).collect();
        assert!(
            unlisted.is_empty(),
            "dispatched but not Ready — a verb no shell will ever offer: {unlisted:?}"
        );
    }

    /// The other half of the same drift, from the direction a user feels it.
    #[test]
    fn a_planned_verb_says_it_is_coming_and_a_typo_says_it_is_a_typo() {
        let planned = vocabulary::planned_names();
        let verb = planned.first().expect("the table carries planned verbs");
        let failure = unknown_subcommand(verb);
        assert_eq!(failure.code, EXIT_USAGE);
        assert!(
            failure.message.contains("designed but not implemented"),
            "{failure:?}"
        );

        let typo = unknown_subcommand("frobnicate");
        assert_eq!(typo.code, EXIT_USAGE);
        assert!(typo.message.contains("unknown subcommand"), "{typo:?}");
    }

    #[test]
    fn help_wins_over_the_gui_launch_and_exits_zero() {
        let (code, text) = capture(&["slopdesk", "--help"], &Environment::default());
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("usage: slopdesk"), "{text}");

        let (code, spelled) = capture(&["slopdesk", "help"], &Environment::default());
        assert_eq!(code, Ok(0));
        assert_eq!(spelled, text, "both spellings print the same page");
    }

    #[test]
    fn an_unknown_flag_and_a_dangling_one_are_usage_errors_by_name() {
        let (code, _) = capture(&["slopdesk", "--bogus"], &Environment::default());
        assert_eq!(
            code,
            Err(Failure::usage("unknown flag '--bogus' (run with --help)"))
        );

        let (code, _) = capture(&["slopdesk", "--socket"], &Environment::default());
        assert_eq!(code, Err(Failure::usage("'--socket' requires a value")));
    }

    #[test]
    fn an_unknown_subcommand_is_refused_before_any_socket_work() {
        let (code, _) = capture(&["slopdesk", "frobnicate"], &Environment::default());
        let failure = code.expect_err("there is no such verb");
        assert_eq!(failure.code, EXIT_USAGE);
    }

    #[test]
    fn the_program_name_is_the_basename_however_it_was_invoked() {
        assert_eq!(program_name(Some("/usr/local/bin/slopdesk")), "slopdesk");
        assert_eq!(program_name(Some("./sd")), "sd");
        assert_eq!(program_name(Some("/usr/bin/")), "slopdesk");
        assert_eq!(program_name(None), "slopdesk");
    }

    #[test]
    fn an_empty_environment_variable_reads_as_unset() {
        let environment = Environment::from_pairs(&[("HOME", ""), ("SHELL", "/bin/zsh")]);
        assert_eq!(environment.get("HOME"), None);
        assert_eq!(environment.home(), "/");
        assert_eq!(environment.get("SHELL"), Some("/bin/zsh"));
    }

    /// `version` answers without a socket, and the number lands in the SECOND whitespace field of
    /// the first line — the shape `slopdesk-release package` parses out of a built binary.
    #[test]
    fn the_version_banner_puts_the_number_where_the_packager_looks_for_it() {
        let text = version_summary(&Environment::default());
        let first = text.lines().next().expect("a first line");
        let mut fields = first.split_whitespace();
        assert_eq!(fields.next(), Some("slopdesk"));
        assert_eq!(fields.next(), Some(env!("CARGO_PKG_VERSION")));

        let stamped = version_summary(&Environment::from_pairs(&[(
            crate::version::BUILD_HASH_ENV_KEY,
            "a0e99e5",
        )]));
        assert!(stamped.contains("(a0e99e5)"), "{stamped}");
    }
}
