//! The two blocking verbs: wrap a command, or wait for a Claude session to settle.
//!
//! `watch <cmd>` runs IN a pane and prints nothing of its own — it brackets the wrapped command
//! with the OSC bytes the host's sniffer already parses, so the tab shows a spinner while the
//! command runs and a badge when it stops. The bytes are [`slopdesk_wire::osc`]'s, the same crate
//! the host parses with, so the wrapper cannot emit a sequence the host would drop.
//!
//! `watch:claude <id>` blocks until the named session is at rest. Every decision it makes belongs
//! to [`slopdesk_agent::watch`] — which observation a reply is, whether that is at rest, what the
//! deadline means — so what is left here is the poll loop, and the poll loop takes its clock as an
//! argument. That is the whole reason the loop is a test rather than a compiled-and-reviewed branch
//! inside a `main`: a fake clock finishes a five-second block instantly.

use std::io::Write;

use slopdesk_agent::watch::{WatchObservation, WatchStep, block_deadline_nanos, decide};
use slopdesk_wire::osc;

use crate::clientctl;
use crate::shell::{Control, Ctx, Failure, Io, Run, print};

/// How long between polls of `agent-status`.
const POLL_INTERVAL_NANOS: u64 = 250 * 1_000_000;

/// The exit code a command that could not be launched at all reports.
///
/// 127 is the shell's own convention for "command not found", and `watch` is a wrapper — a caller
/// that scripts around it should read the same number it would have read without the wrapper.
pub const EXIT_NOT_LAUNCHED: u8 = 127;

/// The monotonic clock the poll loop reads, so a test can supply its own.
pub trait Clock {
    /// Nanoseconds since an arbitrary fixed origin. Only differences are ever taken.
    fn now_nanos(&self) -> u64;

    /// Blocks for `nanos`.
    fn sleep_nanos(&self, nanos: u64);
}

/// The real one: `Instant`, against a process-wide origin taken at first use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MonotonicClock;

impl Clock for MonotonicClock {
    fn now_nanos(&self) -> u64 {
        static ORIGIN: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
        u64::try_from(ORIGIN.get_or_init(std::time::Instant::now).elapsed().as_nanos()).unwrap_or(u64::MAX)
    }

    fn sleep_nanos(&self, nanos: u64) {
        std::thread::sleep(std::time::Duration::from_nanos(nanos));
    }
}

// ---------------------------------------------------------------------------------------------
// watch
// ---------------------------------------------------------------------------------------------

/// What a parsed `watch` invocation is.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct WatchPlan {
    /// The wrapped command and its arguments, verbatim.
    pub command: Vec<String>,
    /// Whether `-q`/`--quiet` suppressed the finish notification.
    pub quiet: bool,
}

/// Parses `watch [-q] [--] <cmd> [args…]`.
///
/// Flag parsing stops at the first operand: a leading `-q`/`--quiet` is consumed, an optional bare
/// `--` ends option parsing, and everything from the first non-flag token onward is the wrapped
/// command VERBATIM — so a flag meant for the command is never re-interpreted here.
///
/// # Errors
/// An invocation with no command to wrap.
pub fn parse_watch(rest: &[String]) -> Result<WatchPlan, Failure> {
    let mut plan = WatchPlan::default();
    let mut collecting = false;
    for token in rest {
        if collecting {
            plan.command.push(token.clone());
            continue;
        }
        match token.as_str() {
            "-q" | "--quiet" => plan.quiet = true,
            // Explicit end-of-options; the command starts after this.
            "--" => collecting = true,
            _ => {
                // The first operand: this and everything after it is the command.
                plan.command.push(token.clone());
                collecting = true;
            },
        }
    }
    if plan.command.is_empty() {
        return Err(Failure::usage("watch: requires a <command>"));
    }
    Ok(plan)
}

/// `watch [-q] <cmd> [args…]` — a spinner while it runs, a badge when it stops, and a desktop
/// notification unless `-q`.
///
/// # Errors
/// An invocation with no command, or a write to the terminal that failed.
pub fn watch(io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let plan = parse_watch(rest)?;
    run_watch(io, &plan, ctx)
}

/// Writes raw bytes to the sink, which for the real program is the pane's PTY — where the host's
/// OSC sniffer reads them.
fn write_bytes(sink: &mut dyn Write, bytes: &[u8]) -> Result<(), Failure> {
    sink.write_all(bytes)
        .map_err(|error| Failure::plain(format!("write failed: {error}")))
}

/// The finish half: the badge, then (unless quiet) the watch-finish banner.
fn finish(io: &mut Io<'_>, plan: &WatchPlan, exit_code: i32) -> Run {
    write_bytes(io.out, &osc::finish_bytes(exit_code))?;
    if !plan.quiet {
        // The watch-finish-SPECIFIC notification form, so the host and client route it to the
        // dedicated "Notify on Watch Finish" toggle rather than the generic explicit-OSC master
        // switch. `-q` is the LOCAL suppression of the same thing.
        write_bytes(
            io.out,
            &osc::watch_finish_notification_bytes(&osc::watch_finish_message(&plan.command, exit_code)),
        )?;
    }
    io.out
        .flush()
        .map_err(|error| Failure::plain(format!("flush failed: {error}")))?;
    Ok(u8::try_from(exit_code).unwrap_or(1))
}

/// Spawns the wrapped command with the pane's stdio inherited, bracketed by the OSC bytes.
///
/// `/usr/bin/env <cmd> <args…>` execs it directly — PATH lookup, no shell, argv unchanged. Shell
/// features (pipes, `&&`) require an explicit `watch sh -c "…"`, by design: a wrapper that re-split
/// its argv would be a second, worse shell.
fn run_watch(io: &mut Io<'_>, plan: &WatchPlan, ctx: &Ctx) -> Run {
    // Spinner up first, and FLUSHED, so the badge is live the instant the command starts — the
    // child inherits the real stdout and would otherwise print ahead of a buffered escape.
    write_bytes(io.out, &osc::spinner_bytes())?;
    io.out
        .flush()
        .map_err(|error| Failure::plain(format!("flush failed: {error}")))?;

    let spawned = std::process::Command::new("/usr/bin/env")
        .args(&plan.command)
        .status();
    let status = match spawned {
        Ok(status) => status,
        Err(error) => {
            let name = plan.command.first().map_or("", String::as_str);
            print(
                io.err,
                &format!("{}: watch: failed to run '{name}': {error}\n", ctx.program),
            )?;
            return finish(io, plan, i32::from(EXIT_NOT_LAUNCHED));
        },
    };
    finish(io, plan, exit_code_of(status))
}

/// The code a finished child reports, with a signal death surfaced as `128 + signo`.
///
/// A signal-terminated child has no exit status of its own; the shell convention makes one, and it
/// is non-zero, so the badge and the propagated code both say the command failed.
fn exit_code_of(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt as _;

    status
        .code()
        .or_else(|| status.signal().map(|signal| 128_i32.wrapping_add(signal)))
        .unwrap_or(1)
}

// ---------------------------------------------------------------------------------------------
// watch:claude
// ---------------------------------------------------------------------------------------------

/// What a parsed `watch:claude` invocation is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudePlan {
    /// The session id to wait on.
    pub id: String,
    /// A bounded block in milliseconds, or `None` for the default unbounded one.
    pub block_timeout_ms: Option<i64>,
}

/// Parses `watch:claude <id> [--block-timeout <ms>]`.
///
/// # Errors
/// A missing id, a second one, an unknown flag, or a `--block-timeout` that is not a positive
/// integer.
pub fn parse_watch_claude(rest: &[String]) -> Result<ClaudePlan, Failure> {
    let mut id: Option<&str> = None;
    let mut block_timeout_ms: Option<i64> = None;
    let mut index = 0;
    while let Some(argument) = rest.get(index) {
        match argument.as_str() {
            "--block-timeout" => {
                let raw = rest
                    .get(index.saturating_add(1))
                    .ok_or_else(|| Failure::usage("watch:claude: --block-timeout requires a value (ms)"))?;
                let value = raw.parse::<i64>().ok().filter(|ms| *ms > 0).ok_or_else(|| {
                    Failure::usage("watch:claude: --block-timeout must be a positive integer (ms)")
                })?;
                block_timeout_ms = Some(value);
                index = index.saturating_add(1);
            },
            other if other.starts_with('-') => {
                return Err(Failure::usage(format!("watch:claude: unknown flag '{other}'")));
            },
            other => {
                if id.is_some() {
                    return Err(Failure::usage(format!(
                        "watch:claude: unexpected argument '{other}'"
                    )));
                }
                id = Some(other);
            },
        }
        index = index.saturating_add(1);
    }
    let id = id
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failure::usage("watch:claude: requires a session <id>"))?;
    Ok(ClaudePlan {
        id: id.to_owned(),
        block_timeout_ms,
    })
}

/// `watch:claude <id> [--block-timeout <ms>]` — block until the session is at rest, then exit with
/// the outcome's code: `0` settled or closed, `4` never seen, `9` the deadline elapsed.
///
/// The block is UNBOUNDED by default. The global `--timeout` bounds each poll's IPC round-trip
/// ONLY: feeding it into the block would exit `9` after three seconds, which is shorter than
/// essentially any real turn.
///
/// # Errors
/// A malformed invocation, or a poll the app did not answer.
pub fn watch_claude(ctl: &mut impl Control, rest: &[String], clock: &impl Clock) -> Run {
    let plan = parse_watch_claude(rest)?;
    let deadline = block_deadline_nanos(clock.now_nanos(), plan.block_timeout_ms);
    let mut has_ever_been_seen = false;

    loop {
        let result = ctl.call(clientctl::AGENT_STATUS, clientctl::agent_status_params(&plan.id))?;
        let observation = WatchObservation::decode(
            result
                .get("seen")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            result.get("status").and_then(serde_json::Value::as_str),
        );
        // A pane that resolves — whether or not its agent has reported yet — counts as seen, so a
        // later disappearance reads as "closed" (exit 0) rather than "never seen" (exit 4).
        if matches!(
            observation,
            WatchObservation::Status(_) | WatchObservation::SeenNoStatus
        ) {
            has_ever_been_seen = true;
        }

        let now = clock.now_nanos();
        let exceeded = deadline.is_some_and(|at| now >= at);
        match decide(observation, has_ever_been_seen, exceeded) {
            WatchStep::Finished(outcome) => {
                return Ok(u8::try_from(outcome.code()).unwrap_or(1));
            },
            WatchStep::KeepPolling => {
                // Sleep up to one interval; with a bounded block, never past the deadline.
                let remaining = deadline.filter(|at| *at > now).map_or(POLL_INTERVAL_NANOS, |at| {
                    POLL_INTERVAL_NANOS.min(at.saturating_sub(now))
                });
                clock.sleep_nanos(remaining);
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::cell::Cell;

    use serde_json::Value;

    use super::{Clock, parse_watch, parse_watch_claude, watch, watch_claude};
    use crate::args::OutputFormat;
    use crate::clientctl::Params;
    use crate::shell::commands::tests::{args, ctx, drive};
    use crate::shell::{Control, EXIT_USAGE, Failure};

    /// A clock that only moves when a sleep asks it to, so a five-second block finishes instantly.
    #[derive(Debug, Default)]
    struct FakeClock {
        now: Cell<u64>,
    }

    impl Clock for FakeClock {
        fn now_nanos(&self) -> u64 {
            self.now.get()
        }

        fn sleep_nanos(&self, nanos: u64) {
            self.now.set(self.now.get().saturating_add(nanos));
        }
    }

    /// A control that answers a scripted sequence of replies, repeating the last one forever.
    #[derive(Debug, Default)]
    struct Replies {
        answers: Vec<String>,
        calls: usize,
    }

    impl Replies {
        fn of(answers: &[&str]) -> Self {
            Self {
                answers: answers.iter().map(|text| (*text).to_owned()).collect(),
                calls: 0,
            }
        }
    }

    impl Control for Replies {
        fn call(&mut self, _method: &str, _params: Params) -> Result<Params, Failure> {
            let index = self.calls.min(self.answers.len().saturating_sub(1));
            self.calls = self.calls.saturating_add(1);
            let text = self.answers.get(index).cloned().unwrap_or_default();
            Ok(serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|value| value.as_object().cloned())
                .unwrap_or_default())
        }
    }

    /// The parse stops at the first operand, so the wrapped command keeps its own flags.
    #[test]
    fn the_wrapped_command_keeps_every_flag_that_belongs_to_it() {
        let plan = parse_watch(&args(&["-q", "cargo", "test", "--quiet"])).expect("a command");
        assert!(plan.quiet);
        assert_eq!(plan.command, args(&["cargo", "test", "--quiet"]));

        // A `-q` AFTER the command is the command's, not ours.
        let plan = parse_watch(&args(&["cargo", "-q", "build"])).expect("a command");
        assert!(!plan.quiet);
        assert_eq!(plan.command, args(&["cargo", "-q", "build"]));

        // A bare `--` ends option parsing without joining the command.
        let plan = parse_watch(&args(&["--quiet", "--", "-q"])).expect("a command");
        assert!(plan.quiet);
        assert_eq!(plan.command, args(&["-q"]));
    }

    #[test]
    fn a_watch_with_nothing_to_wrap_is_a_usage_error() {
        let failure = parse_watch(&args(&["-q"])).expect_err("nothing to run");
        assert_eq!(failure.code, EXIT_USAGE);
        assert_eq!(failure.message, "watch: requires a <command>");
    }

    /// The spinner goes out before the command runs and the badge after it, with the exit code
    /// propagated — asserted against a real `/usr/bin/env true`, which is the whole wrapper.
    #[test]
    fn a_watched_command_is_bracketed_by_the_spinner_and_the_badge() {
        let (code, text) = drive(|io| watch(io, &args(&["-q", "true"]), &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        let spinner = String::from_utf8(slopdesk_wire::osc::spinner_bytes()).expect("utf8");
        let cleared = String::from_utf8(slopdesk_wire::osc::finish_bytes(0)).expect("utf8");
        assert_eq!(text, format!("{spinner}{cleared}"), "quiet emits no banner");

        let (code, text) = drive(|io| watch(io, &args(&["-q", "false"]), &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(1));
        let errored = String::from_utf8(slopdesk_wire::osc::finish_bytes(1)).expect("utf8");
        assert!(text.ends_with(&errored), "a non-zero exit holds the error badge");

        // Without `-q` the finish banner follows the badge.
        let (code, text) = drive(|io| watch(io, &args(&["true"]), &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert!(
            text.len() > spinner.len() + cleared.len(),
            "the banner is there too"
        );
    }

    /// A command that cannot be launched still gets its badge, and reports the shell's own 127.
    #[test]
    fn a_command_that_does_not_exist_still_finishes_the_badge() {
        let (code, text) = drive(|io| {
            watch(
                io,
                &args(&["-q", "slopdesk-no-such-command-at-all"]),
                &ctx(OutputFormat::Text),
            )
        });
        assert_eq!(code, Ok(127));
        let errored = String::from_utf8(slopdesk_wire::osc::finish_bytes(127)).expect("utf8");
        assert!(text.ends_with(&errored), "{text:?}");
    }

    #[test]
    fn every_malformed_claude_invocation_says_which_part_was_wrong() {
        for (rest, message) in [
            (
                vec!["--block-timeout"],
                "watch:claude: --block-timeout requires a value (ms)",
            ),
            (
                vec!["s1", "--block-timeout", "0"],
                "watch:claude: --block-timeout must be a positive integer (ms)",
            ),
            (
                vec!["s1", "--block-timeout", "soon"],
                "watch:claude: --block-timeout must be a positive integer (ms)",
            ),
            (vec!["--force"], "watch:claude: unknown flag '--force'"),
            (vec!["s1", "s2"], "watch:claude: unexpected argument 's2'"),
            (vec![], "watch:claude: requires a session <id>"),
            (vec![""], "watch:claude: requires a session <id>"),
        ] {
            let failure = parse_watch_claude(&args(&rest)).expect_err("malformed");
            assert_eq!(failure.code, EXIT_USAGE);
            assert_eq!(failure.message, message);
        }

        let plan = parse_watch_claude(&args(&["s1", "--block-timeout", "500"])).expect("well-formed");
        assert_eq!(plan.id, "s1");
        assert_eq!(plan.block_timeout_ms, Some(500));
    }

    /// The loop polls until the session settles, and the poll count is what proves it waited.
    #[test]
    fn a_working_session_is_polled_until_it_settles() {
        let mut ctl = Replies::of(&[
            r#"{"seen":true,"status":"working"}"#,
            r#"{"seen":true,"status":"working"}"#,
            r#"{"seen":true,"status":"idle"}"#,
        ]);
        let clock = FakeClock::default();
        assert_eq!(watch_claude(&mut ctl, &args(&["s1"]), &clock), Ok(0));
        assert_eq!(ctl.calls, 3);
        assert_eq!(
            clock.now_nanos(),
            2 * 250 * 1_000_000,
            "two sleeps of one interval"
        );
    }

    /// An id nobody knows is exit 4 on the FIRST poll; one that was seen and then vanished is a
    /// session that closed, which is exit 0.
    #[test]
    fn never_seen_and_closed_are_told_apart_by_what_came_before() {
        let mut ctl = Replies::of(&[r#"{"seen":false}"#]);
        let clock = FakeClock::default();
        assert_eq!(watch_claude(&mut ctl, &args(&["ghost"]), &clock), Ok(4));
        assert_eq!(ctl.calls, 1, "there is nothing to wait for");

        let mut ctl = Replies::of(&[r#"{"seen":true,"status":"working"}"#, r#"{"seen":false}"#]);
        assert_eq!(
            watch_claude(&mut ctl, &args(&["s1"]), &FakeClock::default()),
            Ok(0)
        );
    }

    /// A bounded block that elapses is exit 9 — and the sleep never overshoots the deadline.
    #[test]
    fn a_bounded_block_that_elapses_exits_nine_without_sleeping_past_it() {
        let mut ctl = Replies::of(&[r#"{"seen":true,"status":"working"}"#]);
        let clock = FakeClock::default();
        assert_eq!(
            watch_claude(&mut ctl, &args(&["s1", "--block-timeout", "400"]), &clock),
            Ok(9)
        );
        assert_eq!(
            clock.now_nanos(),
            400 * 1_000_000,
            "stopped exactly at the deadline"
        );
    }

    /// A just-in-time finish is never reported as a timeout: a settled verdict wins over an expired
    /// deadline, which is the whole reason the decision belongs to `slopdesk-agent`.
    #[test]
    fn a_session_that_settles_on_the_deadline_poll_still_exits_zero() {
        let mut ctl = Replies::of(&[
            r#"{"seen":true,"status":"working"}"#,
            r#"{"seen":true,"status":"done"}"#,
        ]);
        let clock = FakeClock::default();
        assert_eq!(
            watch_claude(&mut ctl, &args(&["s1", "--block-timeout", "100"]), &clock),
            Ok(0)
        );
    }
}
