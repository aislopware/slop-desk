//! One function per subcommand: parse its flags, call the verb, render the answer, pick the exit
//! code.
//!
//! Every one of them talks to the host through the [`Control`] trait rather than a socket, so a
//! test can drive a whole subcommand — including the exit code it would hand the shell — against a
//! canned response. That is the part of `main.swift` no test could reach.

use std::io::Write;

use serde_json::Value;

use crate::protocol::{
    Params, encode_request_line, encode_response_line, kill_params, last_output_params, list_panes_params,
    read_params, report_params, resize_params, run_params, screen_params, spawn_params, subscribe_all_params,
    subscribe_params, wait_params, wait_state_params, write_params,
};
use crate::render::{last_lines, last_output_report, list_panes_table, newline_terminated, truncate_ms};

/// The default block/match wait, in milliseconds — the same 30 s the server falls back to.
pub const DEFAULT_TIMEOUT_MS: f64 = 30000.0;

/// The exit code a `run --wait` that never saw its block hands back: `timeout(1)`'s convention,
/// deliberately distinct from a command's own exit 1.
pub const EXIT_TIMEOUT: u8 = 124;

/// The host end, as the subcommands need it.
pub trait Control {
    /// Sends one request and returns the decoded response object.
    ///
    /// # Errors
    /// Any transport failure, or a response that is not a JSON object.
    fn call(&mut self, method: &str, params: Params) -> Result<Params, String>;

    /// Sends a `subscribe` request and pumps its event lines to `sink` until the host hangs up.
    ///
    /// # Errors
    /// Any transport failure, or the host refusing the subscription.
    fn stream(&mut self, params: Params, sink: &mut dyn Write) -> Result<u8, String>;
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
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Io { out, err }")
    }
}

/// The pieces of the environment the subcommands read.
#[derive(Debug, Default, Clone)]
pub struct Ctx {
    /// `$HOME`, for shortening a pane's cwd. Empty disables the shortening.
    pub home: String,
    /// `$SHELL`, for `spawn --cmd`'s `<shell> -c`.
    pub shell: String,
    /// `argv[0]`'s basename, for the `run --wait` status line.
    pub program: String,
}

fn as_str<'a>(obj: &'a Params, key: &str) -> Option<&'a str> {
    obj.get(key).and_then(Value::as_str)
}

fn result_of(obj: &Params) -> Params {
    obj.get("result")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

/// Fails unless the response says `ok: true`, naming the verb that was refused.
fn require_ok(obj: &Params, context: &str) -> Result<(), String> {
    if obj.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    let message = as_str(obj, "error").unwrap_or("(no error message)");
    Err(format!("{context}: {message}"))
}

fn print(sink: &mut dyn Write, text: &str) -> Result<(), String> {
    sink.write_all(text.as_bytes())
        .map_err(|err| format!("write failed: {err}"))
}

/// Emits the whole response as one sorted NDJSON line — every subcommand's `--json` mode.
fn print_json(io: &mut Io<'_>, obj: &Params) -> Result<u8, String> {
    print(io.out, &encode_response_line(obj))?;
    print(io.out, "\n")?;
    Ok(0)
}

fn parse_positive_int(raw: &str, flag: &str) -> Result<i64, String> {
    raw.parse::<i64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| format!("{flag} requires a positive integer"))
}

fn parse_bounded_int(raw: &str, flag: &str, low: i64, high: i64) -> Result<i64, String> {
    raw.parse::<i64>()
        .ok()
        .filter(|n| *n >= low && *n <= high)
        .ok_or_else(|| format!("{flag} must be {low}..{high}"))
}

fn parse_positive_f64(raw: &str, flag: &str) -> Result<f64, String> {
    raw.parse::<f64>()
        .ok()
        .filter(|n| *n > 0.0)
        .ok_or_else(|| format!("{flag} requires a positive number"))
}

/// Reads the value that follows a flag, or names the flag that was left dangling.
fn value_after<'a>(rest: &'a [String], idx: usize, flag: &str) -> Result<&'a str, String> {
    rest.get(idx + 1)
        .map(String::as_str)
        .ok_or_else(|| format!("{flag} requires a value"))
}

/// The pane id every per-pane subcommand takes as its first positional argument.
fn pane_id<'a>(rest: &'a [String], verb: &str) -> Result<&'a str, String> {
    rest.first()
        .map(String::as_str)
        .ok_or_else(|| format!("{verb} requires <paneId>"))
}

// ---------------------------------------------------------------------------------------------
// list-panes
// ---------------------------------------------------------------------------------------------

/// `list-panes` — every live pane, as a table or as the raw response.
///
/// # Errors
/// A transport failure or a refused verb.
pub fn list_panes(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>, ctx: &Ctx) -> Result<u8, String> {
    let json_mode = rest.iter().any(|a| a == "--json");
    let obj = ctl.call("list-panes", list_panes_params())?;
    require_ok(&obj, "list-panes")?;
    if json_mode {
        return print_json(io, &obj);
    }
    let result = result_of(&obj);
    let panes = result
        .get("panes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    print(io.out, &list_panes_table(&panes, &ctx.home))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// read
// ---------------------------------------------------------------------------------------------

/// `read` — the pane's scrollback.
///
/// # Errors
/// An unknown flag, a missing pane id, a transport failure, or a refused verb.
pub fn read(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "read")?;
    let mut keep_ansi = false;
    let mut limit: Option<i64> = None;
    let mut full_ring = false;
    let mut unwrapped = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--ansi" => keep_ansi = true,
            // Explicit "the whole ring" — overrides any --lines cap.
            "--full" => full_ring = true,
            "--unwrapped" | "--recent" => unwrapped = true,
            "--lines" => {
                limit = Some(parse_positive_int(value_after(rest, idx, "--lines")?, "--lines")?);
                idx += 1;
            },
            other => return Err(format!("unknown flag for read: {other}")),
        }
        idx += 1;
    }
    if full_ring {
        limit = None;
    }

    let obj = ctl.call(
        "read",
        read_params(pane, !keep_ansi, unwrapped, if unwrapped { limit } else { None }),
    )?;
    require_ok(&obj, "read")?;
    let result = result_of(&obj);
    let text = as_str(&result, "text").unwrap_or("");

    // On the plain path the host returns the whole snapshot and the cap is applied here; with
    // `--unwrapped` the host already applied it and built `text` out of the logical lines.
    let trimmed = match (unwrapped, limit) {
        (false, Some(n)) => last_lines(text, usize::try_from(n).unwrap_or(usize::MAX)),
        _ => text.to_owned(),
    };
    print(io.out, &newline_terminated(&trimmed))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// screen
// ---------------------------------------------------------------------------------------------

/// `screen` — the rendered grid, as the host's VT model draws it.
///
/// # Errors
/// An unknown flag, an out-of-range size, a transport failure, or a refused verb.
pub fn screen(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "screen")?;
    let mut rows = None;
    let mut cols = None;
    let mut json_mode = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--rows" => {
                rows = Some(parse_bounded_int(
                    value_after(rest, idx, "--rows")?,
                    "--rows",
                    1,
                    512,
                )?);
                idx += 1;
            },
            "--cols" => {
                cols = Some(parse_bounded_int(
                    value_after(rest, idx, "--cols")?,
                    "--cols",
                    1,
                    1024,
                )?);
                idx += 1;
            },
            "--json" => json_mode = true,
            other => return Err(format!("unknown flag for screen: {other}")),
        }
        idx += 1;
    }
    let obj = ctl.call("screen", screen_params(pane, rows, cols))?;
    require_ok(&obj, "screen")?;
    if json_mode {
        return print_json(io, &obj);
    }
    let result = result_of(&obj);
    print(io.out, &newline_terminated(as_str(&result, "text").unwrap_or("")))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// last-output
// ---------------------------------------------------------------------------------------------

/// `last-output` — the last N closed OSC-133 command blocks.
///
/// # Errors
/// An unknown flag, a bad `--n`, a transport failure, or a refused verb.
pub fn last_output(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "last-output")?;
    let mut n = 1;
    let mut keep_ansi = false;
    let mut json_mode = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--n" => {
                n = parse_positive_int(value_after(rest, idx, "--n")?, "--n")?;
                idx += 1;
            },
            "--ansi" => keep_ansi = true,
            "--json" => json_mode = true,
            other => return Err(format!("unknown flag for last-output: {other}")),
        }
        idx += 1;
    }
    let obj = ctl.call("last-output", last_output_params(pane, n, !keep_ansi))?;
    require_ok(&obj, "last-output")?;
    if json_mode {
        return print_json(io, &obj);
    }
    print(io.out, &last_output_report(&result_of(&obj)))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// write
// ---------------------------------------------------------------------------------------------

/// `write` — raw text and/or named keys into the pane's PTY, text first, no implicit Enter.
///
/// # Errors
/// An unknown flag, neither `--text` nor `--key`, a transport failure, or a refused verb.
pub fn write(ctl: &mut impl Control, rest: &[String]) -> Result<u8, String> {
    let pane = pane_id(rest, "write")?;
    let mut text: Option<String> = None;
    let mut keys: Vec<String> = Vec::new();
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--text" => {
                text = Some(value_after(rest, idx, "--text")?.to_owned());
                idx += 1;
            },
            "--key" => {
                // Comma-separated and/or repeated: `--key C-c,Enter` == `--key C-c --key Enter`.
                keys.extend(value_after(rest, idx, "--key")?.split(',').map(str::to_owned));
                idx += 1;
            },
            other => return Err(format!("unknown flag for write: {other}")),
        }
        idx += 1;
    }
    if text.is_none() && keys.is_empty() {
        return Err("write requires --text \"...\" and/or --key K".to_owned());
    }
    let obj = ctl.call("write", write_params(pane, text.as_deref(), &keys))?;
    require_ok(&obj, "write")?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------------------------

/// `run` — text plus Enter. With `--wait`, blocks for the command's OSC-133 block and exits with
/// the COMMAND's own exit code, so it composes into a script the way `ssh` does.
///
/// # Errors
/// An unknown flag, a missing `--cmd`, a transport failure, or a refused verb.
pub fn run(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>, ctx: &Ctx) -> Result<u8, String> {
    let pane = pane_id(rest, "run")?;
    let mut cmd: Option<String> = None;
    let mut wait = false;
    let mut timeout_ms = DEFAULT_TIMEOUT_MS;
    let mut keep_ansi = false;
    let mut json_mode = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--cmd" => {
                cmd = Some(value_after(rest, idx, "--cmd")?.to_owned());
                idx += 1;
            },
            "--wait" => wait = true,
            "--timeout-ms" => {
                timeout_ms = parse_positive_f64(value_after(rest, idx, "--timeout-ms")?, "--timeout-ms")?;
                idx += 1;
            },
            "--ansi" => keep_ansi = true,
            "--json" => json_mode = true,
            other => return Err(format!("unknown flag for run: {other}")),
        }
        idx += 1;
    }
    let Some(command) = cmd else {
        return Err("run requires --cmd \"...\"".to_owned());
    };

    let obj = ctl.call("run", run_params(pane, &command, wait, timeout_ms, !keep_ansi))?;
    require_ok(&obj, "run")?;
    if !wait {
        return Ok(0);
    }
    if json_mode {
        return print_json(io, &obj);
    }

    let result = result_of(&obj);
    if result.get("matched").and_then(Value::as_bool) != Some(true) {
        let ms = truncate_ms(timeout_ms);
        print(io.err, &format!("{}: timeout after {ms}ms\n", ctx.program))?;
        return Ok(EXIT_TIMEOUT);
    }
    let output = as_str(&result, "output").unwrap_or("");
    print(io.out, output)?;
    // An EMPTY output stays empty — a command that printed nothing must not gain a blank line.
    if !output.is_empty() && !output.ends_with('\n') {
        print(io.out, "\n")?;
    }
    let exit_code = result.get("exitCode").and_then(Value::as_i64);
    let duration = result
        .get("durationMs")
        .and_then(Value::as_i64)
        .map_or_else(String::new, |ms| format!(" ({ms}ms)"));
    let shown = exit_code.map_or_else(|| "?".to_owned(), |c| c.to_string());
    print(io.err, &format!("{}: exit {shown}{duration}\n", ctx.program))?;
    // An unknown or interrupted exit maps to 1; a real one clamps into the shell's 0–255 range.
    Ok(u8::try_from(exit_code.unwrap_or(1).clamp(0, 255)).unwrap_or(1))
}

// ---------------------------------------------------------------------------------------------
// wait
// ---------------------------------------------------------------------------------------------

/// `wait` — block until the pane's output matches a regex, or until its agent state is in a set.
///
/// # Errors
/// An unknown flag, neither or both of `--until`/`--state`, a transport failure, or a refused verb.
pub fn wait(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>, ctx: &Ctx) -> Result<u8, String> {
    let pane = pane_id(rest, "wait")?;
    let mut until: Option<String> = None;
    let mut states: Option<String> = None;
    let mut timeout_ms = DEFAULT_TIMEOUT_MS;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--until" => {
                until = Some(value_after(rest, idx, "--until")?.to_owned());
                idx += 1;
            },
            "--state" => {
                states = Some(value_after(rest, idx, "--state")?.to_owned());
                idx += 1;
            },
            "--timeout-ms" => {
                timeout_ms = parse_positive_f64(value_after(rest, idx, "--timeout-ms")?, "--timeout-ms")?;
                idx += 1;
            },
            other => return Err(format!("unknown flag for wait: {other}")),
        }
        idx += 1;
    }
    let params = match (until, states) {
        (Some(pattern), None) => wait_params(pane, &pattern, timeout_ms),
        (None, Some(set)) => wait_state_params(pane, &set, timeout_ms),
        (None, None) => return Err("wait requires --until \"<regex>\" or --state S".to_owned()),
        (Some(_), Some(_)) => return Err("wait takes --until OR --state, not both".to_owned()),
    };

    let obj = ctl.call("wait", params)?;
    require_ok(&obj, "wait")?;
    let result = result_of(&obj);
    let elapsed = result.get("elapsed").and_then(Value::as_f64).unwrap_or(0.0);
    if result.get("matched").and_then(Value::as_bool) == Some(true) {
        // `%.0f` in the original: round, not truncate. The timeout arm below truncates, because
        // that one went through Swift's `Int(_:)`. The two really did differ.
        let rounded = format!("{elapsed:.0}");
        match as_str(&result, "state") {
            Some(state) => print(io.out, &format!("{state} ({rounded}ms)\n"))?,
            None => print(io.out, &format!("matched ({rounded}ms)\n"))?,
        }
        return Ok(0);
    }
    print(
        io.err,
        &format!("{}: timeout after {}ms\n", ctx.program, truncate_ms(elapsed)),
    )?;
    Ok(1)
}

// ---------------------------------------------------------------------------------------------
// spawn / kill / resize / report
// ---------------------------------------------------------------------------------------------

/// `spawn` — a new standalone PTY pane; prints its id.
///
/// # Errors
/// An unknown flag, a malformed `--env`, a transport failure, or a refused verb.
pub fn spawn(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>, ctx: &Ctx) -> Result<u8, String> {
    let mut cmd: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut env: Vec<(String, String)> = Vec::new();
    let mut rows = 24;
    let mut cols = 80;
    let mut idx = 0;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--cmd" => {
                cmd = Some(value_after(rest, idx, "--cmd")?.to_owned());
                idx += 1;
            },
            "--cwd" => {
                cwd = Some(value_after(rest, idx, "--cwd")?.to_owned());
                idx += 1;
            },
            "--env" => {
                let pair = value_after(rest, idx, "--env requires a K=V value")?;
                let Some((key, value)) = pair.split_once('=') else {
                    return Err(format!("--env requires K=V format, got '{pair}'"));
                };
                // Last wins, matching the Swift dictionary assignment.
                env.retain(|(existing, _)| existing != key);
                env.push((key.to_owned(), value.to_owned()));
                idx += 1;
            },
            "--rows" => {
                rows = parse_positive_int(value_after(rest, idx, "--rows")?, "--rows")?;
                idx += 1;
            },
            "--cols" => {
                cols = parse_positive_int(value_after(rest, idx, "--cols")?, "--cols")?;
                idx += 1;
            },
            other => return Err(format!("unknown flag for spawn: {other}")),
        }
        idx += 1;
    }
    let shell = if ctx.shell.is_empty() {
        "/bin/zsh"
    } else {
        ctx.shell.as_str()
    };
    let obj = ctl.call(
        "spawn",
        spawn_params(cmd.as_deref(), cwd.as_deref(), &env, rows, cols, shell),
    )?;
    require_ok(&obj, "spawn")?;
    let result = result_of(&obj);
    print(io.out, &format!("{}\n", as_str(&result, "paneId").unwrap_or("")))?;
    Ok(0)
}

/// `kill` — end a pane by id.
///
/// # Errors
/// A missing pane id, a transport failure, or a refused verb.
pub fn kill(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "kill")?;
    let obj = ctl.call("kill", kill_params(pane))?;
    require_ok(&obj, "kill")?;
    print(io.out, &format!("killed {pane}\n"))?;
    Ok(0)
}

/// `resize` — set the pane's PTY winsize.
///
/// # Errors
/// An unknown flag, a missing or out-of-range size, a transport failure, or a refused verb.
pub fn resize(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "resize")?;
    let mut rows = None;
    let mut cols = None;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--rows" => {
                rows = Some(parse_bounded_int(
                    value_after(rest, idx, "--rows")?,
                    "--rows",
                    1,
                    65535,
                )?);
                idx += 1;
            },
            "--cols" => {
                cols = Some(parse_bounded_int(
                    value_after(rest, idx, "--cols")?,
                    "--cols",
                    1,
                    65535,
                )?);
                idx += 1;
            },
            other => return Err(format!("unknown flag for resize: {other}")),
        }
        idx += 1;
    }
    let Some(r) = rows else {
        return Err("resize requires --rows N".to_owned());
    };
    let Some(c) = cols else {
        return Err("resize requires --cols N".to_owned());
    };
    let obj = ctl.call("resize", resize_params(pane, r, c))?;
    require_ok(&obj, "resize")?;
    print(io.out, &format!("resized {pane} to {r}x{c}\n"))?;
    Ok(0)
}

/// `report` — the agent self-declares its supervision state.
///
/// # Errors
/// An unknown flag, a missing `--state`, a transport failure, or a refused verb.
pub fn report(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "report")?;
    let mut state: Option<String> = None;
    let mut message: Option<String> = None;
    let mut json_mode = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--state" => {
                state = Some(value_after(rest, idx, "--state")?.to_owned());
                idx += 1;
            },
            "--message" => {
                message = Some(value_after(rest, idx, "--message")?.to_owned());
                idx += 1;
            },
            "--json" => json_mode = true,
            other => return Err(format!("unknown flag for report: {other}")),
        }
        idx += 1;
    }
    let Some(state) = state else {
        return Err("report requires --state idle|working|done|blocked".to_owned());
    };
    let obj = ctl.call("report", report_params(pane, &state, message.as_deref()))?;
    require_ok(&obj, "report")?;
    if json_mode {
        return print_json(io, &obj);
    }
    print(io.out, &format!("reported {pane} as {state}\n"))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// subscribe / events
// ---------------------------------------------------------------------------------------------

/// `subscribe` — stream one pane's live output until it exits.
///
/// # Errors
/// An unknown flag, a missing pane id, or a transport failure.
pub fn subscribe(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    let pane = pane_id(rest, "subscribe")?;
    let mut keep_ansi = false;
    let mut idx = 1;
    while let Some(arg) = rest.get(idx) {
        match arg.as_str() {
            "--ansi" => keep_ansi = true,
            other => return Err(format!("unknown flag for subscribe: {other}")),
        }
        idx += 1;
    }
    ctl.stream(subscribe_params(pane, !keep_ansi), io.out)
}

/// `events` — the top-level supervision stream, one line per pane status transition.
///
/// # Errors
/// An unknown flag, or a transport failure.
pub fn events(ctl: &mut impl Control, rest: &[String], io: &mut Io<'_>) -> Result<u8, String> {
    // `--json` is accepted and ignored: these lines are already raw NDJSON.
    if let Some(other) = rest.iter().find(|a| a.as_str() != "--json") {
        return Err(format!("unknown flag for events: {other}"));
    }
    ctl.stream(subscribe_all_params(), io.out)
}

// ---------------------------------------------------------------------------------------------
// The real transport
// ---------------------------------------------------------------------------------------------

/// [`Control`] over the actual `AF_UNIX` socket.
#[derive(Debug, Clone)]
pub struct SocketControl {
    /// The resolved control-socket path.
    pub socket_path: String,
}

impl Control for SocketControl {
    fn call(&mut self, method: &str, params: Params) -> Result<Params, String> {
        let line = encode_request_line("1", method, params);
        let response = crate::client::send_request(&self.socket_path, &line)?;
        crate::protocol::decode_response_line(&response)
            .ok_or_else(|| format!("malformed response from host: {response}"))
    }

    fn stream(&mut self, params: Params, sink: &mut dyn Write) -> Result<u8, String> {
        let line = encode_request_line("1", "subscribe", params);
        crate::client::stream_subscribe(&self.socket_path, &line, sink)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::Write;

    use serde_json::{Value, json};

    use super::{
        Control, Ctx, EXIT_TIMEOUT, Io, Params, events, kill, last_output, list_panes, read, report, resize,
        run, screen, spawn, subscribe, wait, write,
    };

    /// A [`Control`] that answers from a canned script and records what it was asked.
    struct Fake {
        responses: Vec<Value>,
        events: String,
        /// `(method, params)` for every call, in order.
        seen: Vec<(String, Params)>,
    }

    impl Fake {
        fn answering(response: Value) -> Self {
            Self {
                responses: vec![response],
                events: String::new(),
                seen: Vec::new(),
            }
        }

        fn streaming(events: &str) -> Self {
            Self {
                responses: Vec::new(),
                events: events.to_owned(),
                seen: Vec::new(),
            }
        }

        fn ok(result: &Value) -> Self {
            Self::answering(json!({ "id": "1", "ok": true, "result": result }))
        }
    }

    impl Control for Fake {
        fn call(&mut self, method: &str, params: Params) -> Result<Params, String> {
            self.seen.push((method.to_owned(), params));
            let next = if self.responses.len() > 1 {
                self.responses.remove(0)
            } else {
                self.responses
                    .first()
                    .cloned()
                    .unwrap_or_else(|| json!({ "ok": true }))
            };
            Ok(next.as_object().cloned().unwrap_or_default())
        }

        fn stream(&mut self, params: Params, sink: &mut dyn Write) -> Result<u8, String> {
            self.seen.push(("subscribe".to_owned(), params));
            crate::client::pump_events(std::io::Cursor::new(self.events.clone().into_bytes()), sink)
        }
    }

    struct Captured {
        code: Result<u8, String>,
        out: String,
        err: String,
    }

    fn ctx() -> Ctx {
        Ctx {
            home: "/Users/x".to_owned(),
            shell: "/bin/zsh".to_owned(),
            program: "slopdesk-ctl".to_owned(),
        }
    }

    fn drive(fake: &mut Fake, run_it: impl FnOnce(&mut Fake, &mut Io<'_>) -> Result<u8, String>) -> Captured {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = {
            let mut io = Io {
                out: &mut out,
                err: &mut err,
            };
            run_it(fake, &mut io)
        };
        Captured {
            code,
            out: String::from_utf8(out).expect("stdout is UTF-8"),
            err: String::from_utf8(err).expect("stderr is UTF-8"),
        }
    }

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    // MARK: the ok-gate

    #[test]
    fn a_refused_verb_names_the_verb_and_the_hosts_reason() {
        let mut fake = Fake::answering(json!({ "ok": false, "error": "pane not found" }));
        let got = drive(&mut fake, |f, io| kill(f, &argv(&["p"]), io));
        assert_eq!(got.code, Err("kill: pane not found".to_owned()));
    }

    #[test]
    fn a_response_missing_ok_entirely_is_a_refusal_not_a_success() {
        let mut fake = Fake::answering(json!({ "id": "1" }));
        let got = drive(&mut fake, |f, io| kill(f, &argv(&["p"]), io));
        assert_eq!(got.code, Err("kill: (no error message)".to_owned()));
    }

    // MARK: list-panes

    #[test]
    fn list_panes_renders_a_table_and_json_mode_renders_the_whole_response() {
        let response = json!({ "ok": true, "result": { "panes": [{ "paneId": "p", "pid": 7 }] } });
        let mut fake = Fake::answering(response.clone());
        let table = drive(&mut fake, |f, io| list_panes(f, &[], io, &ctx()));
        assert_eq!(table.code, Ok(0));
        assert!(table.out.starts_with("PANE-ID"));

        let mut fake = Fake::answering(response);
        let raw = drive(&mut fake, |f, io| list_panes(f, &argv(&["--json"]), io, &ctx()));
        assert_eq!(raw.code, Ok(0));
        assert_eq!(
            raw.out,
            "{\"ok\":true,\"result\":{\"panes\":[{\"paneId\":\"p\",\"pid\":7}]}}\n"
        );
    }

    // MARK: read

    #[test]
    fn a_plain_read_applies_its_line_cap_locally_and_never_asks_the_host_for_one() {
        let mut fake = Fake::ok(&json!({ "text": "a\nb\nc\nd" }));
        let got = drive(&mut fake, |f, io| read(f, &argv(&["p", "--lines", "2"]), io));
        assert_eq!(got.code, Ok(0));
        assert_eq!(got.out, "c\nd\n");
        let (_, params) = fake.seen.first().expect("one call");
        assert!(
            params.get("lines").is_none(),
            "the host is not asked to trim a plain read"
        );
        assert!(params.get("source").is_none());
    }

    #[test]
    fn an_unwrapped_read_hands_the_cap_to_the_host_and_prints_what_comes_back_untrimmed() {
        let mut fake = Fake::ok(&json!({ "text": "a\nb\nc\nd" }));
        let got = drive(&mut fake, |f, io| {
            read(f, &argv(&["p", "--unwrapped", "--lines", "2"]), io)
        });
        assert_eq!(got.out, "a\nb\nc\nd\n", "the host already applied the cap");
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["source"], Value::from("unwrapped"));
        assert_eq!(params["lines"].to_string(), "2");
    }

    #[test]
    fn full_beats_lines_however_they_are_ordered() {
        for args in [
            argv(&["p", "--lines", "2", "--full"]),
            argv(&["p", "--full", "--lines", "2"]),
        ] {
            let mut fake = Fake::ok(&json!({ "text": "a\nb\nc\nd" }));
            let got = drive(&mut fake, |f, io| read(f, &args, io));
            assert_eq!(got.out, "a\nb\nc\nd\n", "--full reads the whole ring: {args:?}");
        }
    }

    #[test]
    fn recent_is_a_spelling_of_unwrapped() {
        let mut fake = Fake::ok(&json!({ "text": "x" }));
        drive(&mut fake, |f, io| read(f, &argv(&["p", "--recent"]), io));
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["source"], Value::from("unwrapped"));
    }

    #[test]
    fn ansi_inverts_the_strip_flag_the_host_is_sent() {
        let mut fake = Fake::ok(&json!({ "text": "x" }));
        drive(&mut fake, |f, io| read(f, &argv(&["p", "--ansi"]), io));
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["ansiStrip"], Value::from(false));
    }

    #[test]
    fn read_refuses_an_unknown_flag_and_a_missing_pane_by_name() {
        let mut fake = Fake::ok(&json!({}));
        assert_eq!(
            drive(&mut fake, |f, io| read(f, &argv(&["p", "--nope"]), io)).code,
            Err("unknown flag for read: --nope".to_owned())
        );
        assert_eq!(
            drive(&mut fake, |f, io| read(f, &[], io)).code,
            Err("read requires <paneId>".to_owned())
        );
        assert_eq!(
            drive(&mut fake, |f, io| read(f, &argv(&["p", "--lines"]), io)).code,
            Err("--lines requires a value".to_owned())
        );
        assert_eq!(
            drive(&mut fake, |f, io| read(f, &argv(&["p", "--lines", "0"]), io)).code,
            Err("--lines requires a positive integer".to_owned())
        );
    }

    // MARK: screen

    #[test]
    fn screen_bounds_its_grid_and_says_which_bound_was_missed() {
        let mut fake = Fake::ok(&json!({ "text": "grid" }));
        assert_eq!(
            drive(&mut fake, |f, io| screen(f, &argv(&["p", "--rows", "513"]), io)).code,
            Err("--rows must be 1..512".to_owned())
        );
        assert_eq!(
            drive(&mut fake, |f, io| screen(f, &argv(&["p", "--cols", "1025"]), io)).code,
            Err("--cols must be 1..1024".to_owned())
        );
        let ok = drive(&mut fake, |f, io| {
            screen(f, &argv(&["p", "--rows", "40", "--cols", "100"]), io)
        });
        assert_eq!(ok.code, Ok(0));
        assert_eq!(ok.out, "grid\n");
    }

    // MARK: write

    #[test]
    fn write_needs_something_to_send() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        assert_eq!(
            drive(&mut fake, |f, _| write(f, &argv(&["p"]))).code,
            Err("write requires --text \"...\" and/or --key K".to_owned())
        );
    }

    #[test]
    fn keys_accumulate_across_commas_and_repeats_in_the_order_typed() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        drive(&mut fake, |f, _| {
            write(f, &argv(&["p", "--key", "C-c,Enter", "--key", "Up"]))
        });
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["keys"].to_string(), r#"["C-c","Enter","Up"]"#);
    }

    // MARK: run

    #[test]
    fn run_without_wait_prints_nothing_and_succeeds() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        let got = drive(&mut fake, |f, io| {
            run(f, &argv(&["p", "--cmd", "ls"]), io, &ctx())
        });
        assert_eq!(got.code, Ok(0));
        assert_eq!(got.out, "");
        assert_eq!(got.err, "");
    }

    #[test]
    fn run_wait_propagates_the_commands_own_exit_code_and_reports_it_on_stderr() {
        let mut fake =
            Fake::ok(&json!({ "matched": true, "output": "boom\n", "exitCode": 3, "durationMs": 12 }));
        let got = drive(&mut fake, |f, io| {
            run(f, &argv(&["p", "--cmd", "false", "--wait"]), io, &ctx())
        });
        assert_eq!(got.code, Ok(3));
        assert_eq!(got.out, "boom\n");
        assert_eq!(got.err, "slopdesk-ctl: exit 3 (12ms)\n");
    }

    #[test]
    fn run_wait_clamps_an_out_of_range_exit_code_into_the_shells_byte() {
        let mut fake = Fake::ok(&json!({ "matched": true, "output": "", "exitCode": 300 }));
        assert_eq!(
            drive(&mut fake, |f, io| {
                run(f, &argv(&["p", "--cmd", "x", "--wait"]), io, &ctx())
            })
            .code,
            Ok(255)
        );
        let mut fake = Fake::ok(&json!({ "matched": true, "output": "", "exitCode": -1 }));
        assert_eq!(
            drive(&mut fake, |f, io| {
                run(f, &argv(&["p", "--cmd", "x", "--wait"]), io, &ctx())
            })
            .code,
            Ok(0)
        );
    }

    #[test]
    fn run_wait_maps_an_unknown_exit_code_to_one() {
        let mut fake = Fake::ok(&json!({ "matched": true, "output": "" }));
        let got = drive(&mut fake, |f, io| {
            run(f, &argv(&["p", "--cmd", "x", "--wait"]), io, &ctx())
        });
        assert_eq!(got.code, Ok(1));
        assert_eq!(got.err, "slopdesk-ctl: exit ?\n");
    }

    #[test]
    fn run_wait_that_never_saw_its_block_exits_124_with_the_timeout_it_asked_for() {
        let mut fake = Fake::ok(&json!({ "matched": false }));
        let got = drive(&mut fake, |f, io| {
            run(
                f,
                &argv(&["p", "--cmd", "sleep 99", "--wait", "--timeout-ms", "1500"]),
                io,
                &ctx(),
            )
        });
        assert_eq!(got.code, Ok(EXIT_TIMEOUT));
        assert_eq!(got.err, "slopdesk-ctl: timeout after 1500ms\n");
        assert_eq!(got.out, "");
    }

    #[test]
    fn run_wait_leaves_an_empty_output_empty_rather_than_printing_a_blank_line() {
        let mut fake = Fake::ok(&json!({ "matched": true, "output": "", "exitCode": 0 }));
        let got = drive(&mut fake, |f, io| {
            run(f, &argv(&["p", "--cmd", "true", "--wait"]), io, &ctx())
        });
        assert_eq!(got.out, "");
    }

    #[test]
    fn run_wait_terminates_an_unterminated_output() {
        let mut fake = Fake::ok(&json!({ "matched": true, "output": "hi", "exitCode": 0 }));
        let got = drive(&mut fake, |f, io| {
            run(f, &argv(&["p", "--cmd", "x", "--wait"]), io, &ctx())
        });
        assert_eq!(got.out, "hi\n");
    }

    #[test]
    fn run_requires_a_command() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        assert_eq!(
            drive(&mut fake, |f, io| run(f, &argv(&["p"]), io, &ctx())).code,
            Err("run requires --cmd \"...\"".to_owned())
        );
    }

    // MARK: wait

    #[test]
    fn wait_on_a_regex_prints_the_rounded_elapsed_and_exits_zero() {
        let mut fake = Fake::ok(&json!({ "matched": true, "elapsed": 1234.6 }));
        let got = drive(&mut fake, |f, io| {
            wait(f, &argv(&["p", "--until", "\\$"]), io, &ctx())
        });
        assert_eq!(got.code, Ok(0));
        assert_eq!(got.out, "matched (1235ms)\n");
    }

    #[test]
    fn wait_on_a_state_prints_the_state_that_matched() {
        let mut fake = Fake::ok(&json!({ "matched": true, "state": "blocked", "elapsed": 10.0 }));
        let got = drive(&mut fake, |f, io| {
            wait(f, &argv(&["p", "--state", "done,blocked"]), io, &ctx())
        });
        assert_eq!(got.out, "blocked (10ms)\n");
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["state"], Value::from("done,blocked"));
    }

    #[test]
    fn a_wait_timeout_truncates_its_elapsed_and_exits_one() {
        // Deliberately different from the matched arm above: Swift printed `%.0f` on a match and
        // `Int(_:)` on a timeout, so 1234.6 rounds to 1235 there and truncates to 1234 here.
        let mut fake = Fake::ok(&json!({ "matched": false, "elapsed": 1234.6 }));
        let got = drive(&mut fake, |f, io| {
            wait(f, &argv(&["p", "--until", "x"]), io, &ctx())
        });
        assert_eq!(got.code, Ok(1));
        assert_eq!(got.err, "slopdesk-ctl: timeout after 1234ms\n");
    }

    #[test]
    fn wait_needs_exactly_one_of_until_and_state() {
        let mut fake = Fake::ok(&json!({}));
        assert_eq!(
            drive(&mut fake, |f, io| wait(f, &argv(&["p"]), io, &ctx())).code,
            Err("wait requires --until \"<regex>\" or --state S".to_owned())
        );
        assert_eq!(
            drive(&mut fake, |f, io| {
                wait(f, &argv(&["p", "--until", "x", "--state", "done"]), io, &ctx())
            })
            .code,
            Err("wait takes --until OR --state, not both".to_owned())
        );
    }

    // MARK: spawn / resize / report

    #[test]
    fn spawn_prints_the_new_pane_id_and_wraps_the_command_in_the_env_shell() {
        let mut fake = Fake::ok(&json!({ "paneId": "new-pane" }));
        let got = drive(&mut fake, |f, io| spawn(f, &argv(&["--cmd", "ls"]), io, &ctx()));
        assert_eq!(got.code, Ok(0));
        assert_eq!(got.out, "new-pane\n");
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["cmd"].to_string(), r#"["/bin/zsh","-c","ls"]"#);
    }

    #[test]
    fn spawn_falls_back_to_bin_zsh_when_the_environment_names_no_shell() {
        let mut fake = Fake::ok(&json!({ "paneId": "p" }));
        let bare = Ctx {
            home: String::new(),
            shell: String::new(),
            program: "slopdesk-ctl".to_owned(),
        };
        drive(&mut fake, |f, io| spawn(f, &argv(&["--cmd", "ls"]), io, &bare));
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["cmd"].to_string(), r#"["/bin/zsh","-c","ls"]"#);
    }

    #[test]
    fn spawn_refuses_an_env_pair_with_no_equals() {
        let mut fake = Fake::ok(&json!({}));
        assert_eq!(
            drive(&mut fake, |f, io| spawn(f, &argv(&["--env", "NOPE"]), io, &ctx())).code,
            Err("--env requires K=V format, got 'NOPE'".to_owned())
        );
    }

    #[test]
    fn an_env_value_may_itself_contain_an_equals_sign() {
        let mut fake = Fake::ok(&json!({ "paneId": "p" }));
        drive(&mut fake, |f, io| {
            spawn(f, &argv(&["--env", "K=a=b"]), io, &ctx())
        });
        let (_, params) = fake.seen.first().expect("one call");
        assert_eq!(params["env"]["K"], Value::from("a=b"));
    }

    #[test]
    fn resize_needs_both_axes_and_reports_what_it_set() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        assert_eq!(
            drive(&mut fake, |f, io| resize(f, &argv(&["p", "--rows", "40"]), io)).code,
            Err("resize requires --cols N".to_owned())
        );
        let got = drive(&mut fake, |f, io| {
            resize(f, &argv(&["p", "--rows", "40", "--cols", "100"]), io)
        });
        assert_eq!(got.out, "resized p to 40x100\n");
    }

    #[test]
    fn report_needs_a_state_and_confirms_the_one_it_sent() {
        let mut fake = Fake::answering(json!({ "ok": true }));
        assert_eq!(
            drive(&mut fake, |f, io| report(f, &argv(&["p"]), io)).code,
            Err("report requires --state idle|working|done|blocked".to_owned())
        );
        let got = drive(&mut fake, |f, io| report(f, &argv(&["p", "--state", "done"]), io));
        assert_eq!(got.out, "reported p as done\n");
    }

    #[test]
    fn last_output_reports_the_block_it_was_given() {
        let mut fake = Fake::ok(&json!({ "blocks": [{ "command": "ls", "exitCode": 0, "output": "a\n" }] }));
        let got = drive(&mut fake, |f, io| last_output(f, &argv(&["p"]), io));
        assert_eq!(got.out, "$ ls  (exit 0)\na\n");
    }

    // MARK: streaming

    #[test]
    fn subscribe_sends_a_pane_id_and_streams_until_closed() {
        let mut fake = Fake::streaming("{\"event\":\"output\"}\n{\"event\":\"closed\"}\n");
        let got = drive(&mut fake, |f, io| subscribe(f, &argv(&["p"]), io));
        assert_eq!(got.code, Ok(0));
        assert_eq!(got.out, "{\"event\":\"output\"}\n{\"event\":\"closed\"}\n");
        let (method, params) = fake.seen.first().expect("one call");
        assert_eq!(method, "subscribe");
        assert_eq!(params["paneId"], Value::from("p"));
    }

    #[test]
    fn events_sends_no_pane_id_because_the_absence_is_the_whole_contract() {
        let mut fake = Fake::streaming("{\"type\":\"agent_status_changed\"}\n");
        let got = drive(&mut fake, |f, io| events(f, &[], io));
        assert_eq!(got.code, Ok(0));
        let (_, params) = fake.seen.first().expect("one call");
        assert!(
            params.is_empty(),
            "a paneId here would silently narrow the stream to one pane"
        );
    }

    #[test]
    fn events_tolerates_json_and_refuses_anything_else() {
        let mut fake = Fake::streaming("");
        assert_eq!(
            drive(&mut fake, |f, io| events(f, &argv(&["--json"]), io)).code,
            Ok(0)
        );
        assert_eq!(
            drive(&mut fake, |f, io| events(f, &argv(&["--nope"]), io)).code,
            Err("unknown flag for events: --nope".to_owned())
        );
    }
}
