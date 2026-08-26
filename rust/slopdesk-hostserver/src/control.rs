//! The agent-control verbs, as a pure dispatcher over two doors.
//!
//! `AgentControlListener.swift` (1,239) is the herdr/zellij-style control surface an agent drives a
//! pane through: NDJSON on the `AF_UNIX` connections superd hands over, one request object per
//! line. This module is its verb half — `(id, method, params)` in, one response LINE out — and,
//! like every stage-D port before it, what moved was the ORDER rather than an engine. Every
//! decision the Swift reached for is already Rust:
//!
//! - the `wait --until` scan is [`slopdesk_rowscan::waituntil`];
//! - the supervision vocabulary `report` and `wait --state` validate against is
//!   [`slopdesk_agent::supervision`];
//! - the sensitive-basename set the K13 guard consults is [`slopdesk_agent::process`];
//! - the tmux key vocabulary `write` resolves is `slopdesk-wire`'s;
//! - ANSI stripping is [`slopdesk_sanitize::plaintext`], and the prompt-EOL excision
//!   [`slopdesk_sanitize::prompteol`].
//!
//! The Swift reached three of those five through the FFI and one — the prompt-EOL pass — through a
//! round trip to `slopdesk-screend`, because a Swift process had no cheaper way to call Rust it had
//! already written. Here they are function calls.
//!
//! ## Two doors, for the reason D.1 and D.4 have theirs
//! [`ControlHost`] is the SERVER's surface — the pane list, the lookup, spawn, kill, and the
//! cross-pane status fan-out — and [`crate::pane::Pane`] is one pane's. Neither is
//! `slopdesk-hostsession` by name, so the suite can drive all eleven verbs without a PTY, a superd
//! and six threads per entry, and can assert the thing that matters about a REFUSED verb: that it
//! never reached the pane at all.
//!
//! D.5 gave the pane half its own trait, `ControlPane`, sitting on top of the six-method one D.1
//! carved. D.6 merged them, and [`crate::pane`] says why: the live host answers `list-panes` out of
//! the registry and the store, so those tables have to hand back a pane a verb can ASK, and a
//! coerced `dyn Pane` cannot be widened back. What the split protected is intact — those six
//! methods are still the only ones the table and the store call.
//!
//! ## Validate-then-drop, and the trap that named it
//! Every verb answers a malformed request with an error LINE and never with a panic. The Swift
//! carries the reason in a comment: a bare `UInt16(_:)` on a socket-supplied `rows` once trapped on
//! a negative value and took the whole host — every session, every client — down with one bad line.
//! Rust would not trap there, but it would clamp or wrap silently, which is the same bug with a
//! quieter failure, so every numeric argument is RANGE-CHECKED and refused rather than converted.
//!
//! ## The guards are checked before the lookup
//! `write`/`run`/`spawn`/`kill`/`resize` mutate a pane and are gated behind
//! [`IpcGuards::allow_send_keys`]; one that NAMES a pane running a sensitive foreground process is
//! additionally gated behind [`IpcGuards::allow_sensitive_sessions`]. Both default OFF. The order
//! matters and is asserted: a refused verb must not so much as look the pane up, because a lookup
//! is observable — it is how the caller learns the pane exists.
//!
//! No tokens and no crypto, per `CLAUDE.md`: the `WireGuard` mesh is the security boundary and
//! these are host-side guards on a socket that is already `0600` and already pid-free.

use std::sync::Arc;

use serde_json::{Map, Value, json};
use slopdesk_agent::supervision;
use slopdesk_hostsession::{BlockTap, BlockUpdate, OutputTap, TapToken};

use crate::pane::Pane;

/// The largest grid `screen` will render, per axis. The model's own clamp, restated here because
/// the request arrives before any model does.
pub const MAX_SCREEN_ROWS: i64 = 512;
/// See [`MAX_SCREEN_ROWS`].
pub const MAX_SCREEN_COLS: i64 = 1024;

/// The largest window size a `resize` or `spawn` may ask for — `TIOCSWINSZ` takes a `u16`, so this
/// is the type's own ceiling rather than a policy.
pub const MAX_WINDOW_AXIS: i64 = 65535;

/// The default deadline for the two blocking verbs, in milliseconds.
pub const DEFAULT_TIMEOUT_MS: f64 = 30_000.0;

/// The grid `screen` falls back to when the PTY is gone and cannot be measured.
pub const FALLBACK_GRID: (u16, u16) = (24, 80);

/// One row of the `list-panes` answer.
///
/// The optional fields are `None` rather than a zero: JSON has no distinct "unset", and an agent
/// that reads a fabricated `""` or `0` as truth is worse off than one told nothing. They are
/// OMITTED from the encoded object, which is what the Swift did and what `slopdesk-ctl` already
/// parses.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PaneRecord {
    /// The pane's id, as every verb names it.
    pub pane_id: String,
    /// The OSC title, or the shell's own when none was set.
    pub title: String,
    /// The shell's pid.
    pub pid: i32,
    /// Whether the child is still running.
    pub is_alive: bool,
    /// The supervision state, as [`supervision::SupervisionState::name`] spells it.
    pub state: String,
    /// The running command, or the shell when none is.
    pub command: String,
    /// The pane's resolved grid.
    pub rows: u16,
    /// See [`PaneRecord::rows`].
    pub cols: u16,
    /// The pane's working directory, when it could be read.
    pub cwd: Option<String>,
    /// The last command's `$?`, when one has finished.
    pub last_exit_code: Option<i32>,
    /// The human label an agent attached with `report`, when it did.
    pub state_message: Option<String>,
}

/// One transition of the cross-pane supervision stream — what `wait --state` parks on and what
/// `subscribe` with no `paneId` fans out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentStatusEvent {
    /// The pane that moved.
    pub pane_id: String,
    /// Its new state, as [`supervision::SupervisionState::name`] spells it.
    pub state: String,
    /// Whether an agent is present at all — part of the identity of a transition, because the
    /// agent-GONE edge lands on the same `"idle"` string the pane already reported.
    pub agent_present: bool,
    /// The pane's OSC title at the moment it moved.
    pub title: String,
    /// Unix seconds.
    pub ts: i64,
}

/// A watcher of every pane's supervision transitions.
pub trait AgentStatusTap: Send + Sync + core::fmt::Debug {
    /// One transition, as the fan-out published it.
    fn changed(&self, event: &AgentStatusEvent);
}

/// Why a `spawn` did not produce a pane. Carried as a message because that is all the wire has room
/// for, and all an agent can act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnRefused(pub String);

/// The SERVER's surface, as the eleven verbs need it.
///
/// Deliberately five methods and one tap pair rather than "the server": a control verb may name a
/// pane, list them, make one or end one, and watch the states move. Anything wider would let a verb
/// reach into the adoption ladder, which is D.6's and not a socket's.
pub trait ControlHost: Send + Sync + core::fmt::Debug {
    /// Every pane the host holds, in the order it lists them.
    fn list_panes(&self) -> Vec<PaneRecord>;

    /// The pane `pane_id` names, or `None` when nothing does.
    fn lookup_pane(&self, pane_id: &str) -> Option<Arc<dyn Pane>>;

    /// Forks a standalone pane and answers its id.
    ///
    /// Synchronous, unlike the Swift it replaces: `spawnStandalonePane` was `async`, so every call
    /// crossed a `DispatchSemaphore` and an `@unchecked Sendable` box to get back to the connection
    /// thread that asked. There is no executor on this side and the connection thread is the one
    /// that blocks, so the bridge disappears rather than being ported.
    ///
    /// # Errors
    /// [`SpawnRefused`] carries why no pane was made — a bad `cwd`, a superd that would not fork,
    /// a shell that would not start. All three are the caller's to read and none is this side's to
    /// retry.
    fn spawn_standalone(
        &self,
        cmd: Option<&[String]>,
        cwd: Option<&str>,
        env: Option<&Map<String, Value>>,
        rows: u16,
        cols: u16,
    ) -> Result<String, SpawnRefused>;

    /// Ends the pane `pane_id` names, answering whether one was there.
    fn kill_pane(&self, pane_id: &str) -> bool;

    /// Watches every pane's supervision transitions.
    fn add_status_tap(&self, tap: Arc<dyn AgentStatusTap>) -> TapToken;

    /// Retires a watcher [`ControlHost::add_status_tap`] handed back.
    fn remove_status_tap(&self, token: TapToken);
}

/// The resolved send-keys / sensitive-session permissions the dispatcher consults before a mutating
/// verb runs.
///
/// Default-OFF, and only an explicit `"1"` enables — the same idiom every other host gate uses. The
/// client's toggles map onto these through the env bridge, set identically host and client, so a
/// live client edit applies on the NEXT host launch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct IpcGuards {
    /// Whether the mutating verbs may run at all.
    pub allow_send_keys: bool,
    /// Whether a mutating verb may target a pane running a sensitive foreground process.
    pub allow_sensitive_sessions: bool,
}

impl IpcGuards {
    /// Both guards open — the shape a test that is not about the guards asks for.
    #[must_use]
    pub const fn permissive() -> Self {
        Self {
            allow_send_keys: true,
            allow_sensitive_sessions: true,
        }
    }

    /// Resolves both from the host environment.
    #[must_use]
    pub fn resolved() -> Self {
        Self {
            allow_send_keys: enabled("SLOPDESK_IPC_ALLOW_SEND_KEYS"),
            allow_sensitive_sessions: enabled("SLOPDESK_IPC_ALLOW_SENSITIVE"),
        }
    }
}

/// Whether `name` is set to exactly `"1"`. Anything else — unset, `"true"`, `"yes"`, empty — is
/// OFF, so a typo fails closed.
fn enabled(name: &str) -> bool {
    std::env::var(name).is_ok_and(|value| value == "1")
}

/// The verbs that write to a PTY, make a pane or end one.
///
/// The read-only verbs — `list-panes`, `read`, `screen`, `last-output`, `wait`, `report` — are NOT
/// here and are always allowed. `subscribe` is intercepted before dispatch and only streams, so it
/// is read-only too.
pub const MUTATING_VERBS: [&str; 5] = ["write", "run", "spawn", "kill", "resize"];

/// Whether `method` mutates a pane, and so is gated.
#[must_use]
pub fn is_mutating(method: &str) -> bool {
    MUTATING_VERBS.contains(&method)
}

/// Resolves a pane's foreground-process basename, for the sensitive-session gate.
///
/// A function rather than a method on [`ControlHost`] because it is the one thing in the gate that
/// a test must be able to answer WITHOUT a live PTY, and because the probe is a `tcgetpgrp` plus a
/// `sysctl` — an operation about a descriptor rather than about the host.
pub type ForegroundName<'probe> = &'probe dyn Fn(&dyn ControlHost, &str) -> String;

/// The production [`ForegroundName`]: look the pane up and ask it.
///
/// Injected rather than called, because the sensitive gate is the one guard whose REFUSAL a test
/// has to be able to provoke, and provoking it any other way would mean running `ssh` under a PTY.
/// A pane that is gone answers `""`, which no sensitive name matches — the gate protects a live
/// session, and there is nothing to protect once there is no session.
#[must_use]
pub fn probe_foreground_name(host: &dyn ControlHost, pane_id: &str) -> String {
    host.lookup_pane(pane_id)
        .map_or_else(String::new, |pane| pane.foreground_name())
}

// ---------------------------------------------------------------------------------------------- //
// The line grammar
// ---------------------------------------------------------------------------------------------- //

/// One decoded request line.
///
/// OWNED, not borrowed from the line. Three verbs — `run --wait`, `wait` and `wait --state` — park
/// the dispatching thread until a tap fires, so the request outlives the read buffer the pump
/// refills behind it. Three strings per verb is what that costs, and a verb that blocks for a
/// deadline cannot be the place to save them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlRequest {
    /// The caller's correlation id, echoed in the answer.
    pub id: String,
    /// The verb.
    pub method: String,
    /// Whatever the verb takes. An absent `params` decodes to an empty map, not an error.
    pub params: Map<String, Value>,
}

/// Parses one NDJSON request line.
///
/// `None` is validate-then-drop: not JSON, not an object, or `id`/`method` missing or not strings.
/// A dropped line gets NO reply, which is the point — there is no `id` to answer to.
#[must_use]
pub fn parse_request(line: &str) -> Option<ControlRequest> {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
        return None;
    };
    let id = object.get("id")?.as_str()?.to_owned();
    let method = object.get("method")?.as_str()?.to_owned();
    let params = match object.get("params") {
        Some(Value::Object(map)) => map.clone(),
        _ => Map::new(),
    };
    Some(ControlRequest { id, method, params })
}

/// Encodes a success answer as one NDJSON line, newline-terminated.
///
/// An EMPTY result is omitted rather than sent as `{}` — the Swift's shape, and what `slopdesk-ctl`
/// already reads.
#[must_use]
pub fn success(id: &str, result: Value) -> String {
    let empty = result.as_object().is_some_and(Map::is_empty);
    let mut object = Map::new();
    object.insert("id".to_owned(), Value::String(id.to_owned()));
    object.insert("ok".to_owned(), Value::Bool(true));
    if !empty {
        object.insert("result".to_owned(), result);
    }
    encode_line(&Value::Object(object))
}

/// Encodes an error answer as one NDJSON line, newline-terminated.
#[must_use]
pub fn failure(id: &str, message: &str) -> String {
    encode_line(&json!({ "id": id, "ok": false, "error": message }))
}

/// Serialises one answer and frames it.
///
/// `serde_json`'s default map is a `BTreeMap`, so the keys come out sorted — byte for byte what
/// `JSONSerialization`'s `sortedKeys` produced, which is what makes a Rust-served line and a
/// Swift-served one the same line while both exist.
///
/// The fallback is a valid error line rather than an empty string: a client parsing NDJSON must get
/// an object back or it will treat the connection as broken, and "the encoder refused a value it
/// built itself" is not a reason to hang up on it.
pub(crate) fn encode_line(value: &Value) -> String {
    serde_json::to_string(value).map_or_else(
        |_| "{\"ok\":false,\"error\":\"json encode failure\"}\n".to_owned(),
        |mut text| {
            text.push('\n');
            text
        },
    )
}

// ---------------------------------------------------------------------------------------------- //
// Argument readers — each one refuses rather than converting
// ---------------------------------------------------------------------------------------------- //

/// A string argument, or `None` when absent or another type.
fn text<'params>(params: &'params Map<String, Value>, key: &str) -> Option<&'params str> {
    params.get(key)?.as_str()
}

/// A boolean argument, defaulting to `fallback` when absent or another type.
fn flag(params: &Map<String, Value>, key: &str, fallback: bool) -> bool {
    params.get(key).and_then(Value::as_bool).unwrap_or(fallback)
}

/// An integer argument, or `None` when absent or not an integer.
///
/// Not clamped and not truncated: a `rows` of `-1` or `1e9` is a REFUSAL at the call site, because
/// the alternative is a pane silently resized to something the caller did not ask for.
fn whole(params: &Map<String, Value>, key: &str) -> Option<i64> {
    params.get(key)?.as_i64()
}

/// A millisecond deadline. Absent, non-finite or negative reads as the default rather than as an
/// error — the Swift's shape, and the one an agent that omitted it expects.
fn deadline(params: &Map<String, Value>) -> std::time::Duration {
    let millis = params
        .get("timeoutMs")
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && *value >= 0.0)
        .unwrap_or(DEFAULT_TIMEOUT_MS);
    std::time::Duration::try_from_secs_f64(millis / 1000.0)
        .unwrap_or_else(|_| std::time::Duration::from_secs_f64(DEFAULT_TIMEOUT_MS / 1000.0))
}

/// A window axis, checked against `TIOCSWINSZ`'s own type.
fn axis(params: &Map<String, Value>, key: &str, fallback: i64) -> Option<u16> {
    let raw = whole(params, key).unwrap_or(fallback);
    if (1..=MAX_WINDOW_AXIS).contains(&raw) {
        u16::try_from(raw).ok()
    } else {
        None
    }
}

// ---------------------------------------------------------------------------------------------- //
// Text helpers
// ---------------------------------------------------------------------------------------------- //

/// Decodes PTY bytes as text, replacing every non-ASCII byte of an invalid sequence with `?`.
///
/// The same idiom the scrollback readouts use, and deliberately not `from_utf8_lossy`: a pane that
/// emitted one bad byte should not have a run of them collapse into a single `U+FFFD`, because an
/// agent's regex counts columns.
pub(crate) fn lossy_text(bytes: &[u8]) -> String {
    core::str::from_utf8(bytes).map_or_else(
        |_| {
            bytes
                .iter()
                .map(|&byte| if byte < 0x80 { char::from(byte) } else { '?' })
                .collect()
        },
        str::to_owned,
    )
}

/// Excises zsh's `PROMPT_SP` end-of-line mark (`%` plus width fill) from a captured block's tail.
///
/// On the live wire the cluster always abuts the closing `133;D`, which is exactly what the
/// prompt-EOL pass anchors on — but the segmenter strips the OSC marks out of the captured span,
/// leaving the cluster bare. Re-appending a synthetic `D` restores the adjacency the pass keys on
/// (honest: the real `D` DID follow these bytes), reusing its two-sided-SGR false-positive guard
/// rather than duplicating the machine. A command whose real output ends in `%` and spaces stays
/// untouched — no SGR wrapping, a deliberate miss.
///
/// The Swift reached this pass through a round trip to `slopdesk-screend`. It is one function call
/// here, which is the whole reason the sidecar hop existed.
fn strip_prompt_eol_tail(bytes: &[u8]) -> Vec<u8> {
    const ANCHOR: &[u8] = b"\x1b]133;D\x07";
    let mut anchored = Vec::with_capacity(bytes.len() + ANCHOR.len());
    anchored.extend_from_slice(bytes);
    anchored.extend_from_slice(ANCHOR);
    let mut cleaned = slopdesk_sanitize::prompteol::strip(&anchored);
    if cleaned.ends_with(ANCHOR) {
        cleaned.truncate(cleaned.len().saturating_sub(ANCHOR.len()));
    }
    cleaned
}

/// A block's output as an agent reads it: prompt-EOL excised, then optionally ANSI-stripped.
fn block_text(bytes: &[u8], ansi_strip: bool) -> String {
    let trimmed = strip_prompt_eol_tail(bytes);
    if ansi_strip {
        lossy_text(&slopdesk_sanitize::plaintext::strip(&trimmed))
    } else {
        lossy_text(&trimmed)
    }
}

/// `lines`, with the trailing blank rows dropped and the rest joined — the `text` field every
/// grid-shaped answer carries beside its rows.
fn joined_without_trailing_blanks(lines: &[String]) -> String {
    let kept = lines
        .iter()
        .rposition(|line| !line.trim().is_empty())
        .map_or(0, |last| last + 1);
    lines
        .iter()
        .take(kept)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join("\n")
}

// ---------------------------------------------------------------------------------------------- //
// The dispatcher
// ---------------------------------------------------------------------------------------------- //

/// Dispatches one decoded request and answers with a complete NDJSON line.
///
/// BLOCKS the calling thread for `wait` and for `run` with `wait: true`, which is why the
/// connection loop gives every connection a thread of its own rather than a task.
///
/// `foreground_name` resolves a pane's foreground-process basename for the sensitive-session gate;
/// a live host probes the PTY, and a test answers directly.
#[must_use]
pub fn dispatch(
    request: &ControlRequest,
    host: &dyn ControlHost,
    guards: IpcGuards,
    foreground_name: ForegroundName<'_>,
) -> String {
    let id = request.id.as_str();
    let params = &request.params;

    // BEFORE the verb acts, and before any pane lookup: a refused verb must never touch the PTY, and
    // must not answer the question "does this pane exist" either.
    if is_mutating(&request.method) {
        if !guards.allow_send_keys {
            return failure(id, "ipc send-keys disabled");
        }
        // The sensitive gate only covers a verb that NAMES a target — `spawn` makes a fresh pane and
        // has none, so the send-keys gate is all that stands in front of it.
        if !guards.allow_sensitive_sessions
            && let Some(pane_id) = text(params, "paneId")
        {
            let name = foreground_name(host, pane_id);
            if slopdesk_agent::process::is_sensitive(&name) {
                return failure(id, &format!("ipc sensitive-session blocked: {name}"));
            }
        }
    }

    match request.method.as_str() {
        "list-panes" => list_panes(id, host),
        "read" => read_pane(id, params, host),
        "screen" => screen_pane(id, params, host),
        "last-output" => last_output(id, params, host),
        "write" => write_pane(id, params, host),
        "run" => run_pane(id, params, host),
        "wait" => wait_pane(id, params, host),
        "spawn" => spawn_pane(id, params, host),
        "kill" => kill_pane(id, params, host),
        "resize" => resize_pane(id, params, host),
        "report" => report_agent(id, params, host),
        other => failure(id, &format!("unknown method: {other}")),
    }
}

/// Names the pane a verb targets, or answers the refusal in its place.
fn target(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> Result<Arc<dyn Pane>, String> {
    let Some(pane_id) = text(params, "paneId") else {
        return Err(failure(id, "missing params.paneId"));
    };
    host.lookup_pane(pane_id)
        .ok_or_else(|| failure(id, &format!("pane not found: {pane_id}")))
}

/// `list-panes` — every pane, with the unknown fields omitted rather than fabricated.
fn list_panes(id: &str, host: &dyn ControlHost) -> String {
    let panes: Vec<Value> = host
        .list_panes()
        .into_iter()
        .map(|record| {
            let mut item = json!({
                "paneId": record.pane_id,
                "title": record.title,
                "pid": record.pid,
                "isAlive": record.is_alive,
                "state": record.state,
                "command": record.command,
                "rows": record.rows,
                "cols": record.cols,
            });
            if let Some(object) = item.as_object_mut() {
                if let Some(cwd) = record.cwd {
                    object.insert("cwd".to_owned(), Value::String(cwd));
                }
                if let Some(code) = record.last_exit_code {
                    object.insert("lastExitCode".to_owned(), Value::from(code));
                }
                if let Some(message) = record.state_message {
                    object.insert("stateMessage".to_owned(), Value::String(message));
                }
            }
            item
        })
        .collect();
    success(id, json!({ "panes": panes }))
}

/// `read` — the scrollback snapshot, or the LOGICAL-line view when asked for one.
///
/// `source: "unwrapped"` (or its older spelling `"recent"`) answers `{text, lines}` where `lines`
/// are joined chunks split on hard newlines, so an agent's regex is robust to read-chunk
/// boundaries. Only the empty artifact of a terminating newline is dropped — an UNTERMINATED final
/// line is KEPT, because it is typically the live prompt an orchestrator is scraping for.
fn read_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    if matches!(text(params, "source"), Some("unwrapped" | "recent")) {
        // A non-positive or non-integer `lines` is no cap rather than an error — the Swift's shape.
        let limit = whole(params, "lines")
            .filter(|value| *value > 0)
            .and_then(|value| usize::try_from(value).ok());
        let rows = pane.recent_lines(limit);
        let text = rows.join("\n");
        return success(id, json!({ "lines": rows, "text": text }));
    }
    let stripped = flag(params, "ansiStrip", true);
    success(id, json!({ "text": pane.scrollback_text(stripped) }))
}

/// `screen` — the RENDERED grid, so a TUI pane reads as what a human sees rather than byte soup.
///
/// The default size is the pane's LIVE `TIOCGWINSZ`, falling back to 24×80 when the PTY is gone;
/// `rows`/`cols` override it inside the model's own clamp.
fn screen_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    let (live_rows, live_cols) = pane.window_size().unwrap_or(FALLBACK_GRID);
    let Some(rows) = grid_axis(params, "rows", i64::from(live_rows), MAX_SCREEN_ROWS) else {
        return failure(id, "rows must be 1..512");
    };
    let Some(cols) = grid_axis(params, "cols", i64::from(live_cols), MAX_SCREEN_COLS) else {
        return failure(id, "cols must be 1..1024");
    };
    let snapshot = match pane.render_screen(rows, cols) {
        Ok(snapshot) => snapshot,
        Err(reason) => return failure(id, &format!("screen engine unavailable: {reason}")),
    };
    let text = joined_without_trailing_blanks(&snapshot.lines);
    success(
        id,
        json!({
            "rows": snapshot.rows,
            "cols": snapshot.cols,
            "cursorRow": snapshot.cursor_row,
            "cursorCol": snapshot.cursor_col,
            "cursorVisible": snapshot.cursor_visible,
            "altScreen": snapshot.alt_screen,
            "lines": snapshot.lines,
            "text": text,
        }),
    )
}

/// One `screen` axis: absent takes the live size, present is checked against the model's clamp.
fn grid_axis(params: &Map<String, Value>, key: &str, live: i64, ceiling: i64) -> Option<usize> {
    let Some(asked) = whole(params, key) else {
        return usize::try_from(live).ok();
    };
    if (1..=ceiling).contains(&asked) {
        usize::try_from(asked).ok()
    } else {
        None
    }
}

/// `last-output` — the OSC-133 block-aware read: the last N CLOSED blocks, newest last, plus the
/// running one's metadata when a command is executing.
fn last_output(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    let limit = whole(params, "n")
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or(1)
        .max(1);
    let stripped = flag(params, "ansiStrip", true);
    let Some(reply) = pane.blocks(limit) else {
        return failure(id, NO_BLOCK_TAP);
    };
    let items: Vec<Value> = reply
        .recent
        .unwrap_or_default()
        .into_iter()
        .map(|block| {
            let mut item = json!({
                "index": block.index,
                "command": block.command_text,
                "output": block_text(&block.output, stripped),
                "complete": block.complete,
            });
            if let Some(object) = item.as_object_mut() {
                if let Some(code) = block.exit_code {
                    object.insert("exitCode".to_owned(), Value::from(code));
                }
                if let Some(duration) = block.duration_ms {
                    object.insert("durationMs".to_owned(), Value::from(duration));
                }
            }
            item
        })
        .collect();
    let mut result = json!({ "blocks": items });
    if let (Some(object), Some(open)) = (result.as_object_mut(), reply.open) {
        object.insert(
            "running".to_owned(),
            json!({ "command": open.command_text, "outputLen": open.output_len }),
        );
    }
    success(id, result)
}

/// The one message both block verbs answer with when the pane has no segmenter, spelled once so the
/// two cannot drift — a caller keys its fallback to `read` on this text.
const NO_BLOCK_TAP: &str = "no block tap on this pane (SLOPDESK_BLOCKS=0, or it has no shell integration)";

/// `write` — raw text and/or NAMED KEYS, with no implicit Enter.
///
/// `text` goes first, then each token of `keys` in the tmux `send-keys` vocabulary. An unknown
/// token rejects the WHOLE request: a partial key sequence is worse than none, because half of `C-c
/// Enter` is an instruction the caller never gave.
fn write_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    if text(params, "paneId").is_none() {
        return failure(id, "missing params.paneId");
    }
    let typed = text(params, "text");
    let tokens: Vec<&str> = params
        .get("keys")
        .and_then(Value::as_array)
        .map(|array| array.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if typed.is_none() && tokens.is_empty() {
        return failure(id, "missing params.text or params.keys");
    }
    let mut bytes = typed.unwrap_or_default().as_bytes().to_vec();
    for token in tokens {
        let Some(resolved) = slopdesk_workspace::send_keys::key_token(token) else {
            return failure(id, &format!("unknown key: {token}"));
        };
        bytes.extend_from_slice(&resolved);
    }
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    pane.write_raw(&bytes);
    success(id, json!({}))
}

/// `kill` — ends a pane.
fn kill_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let Some(pane_id) = text(params, "paneId") else {
        return failure(id, "missing params.paneId");
    };
    if host.kill_pane(pane_id) {
        success(id, json!({}))
    } else {
        failure(id, &format!("pane not found: {pane_id}"))
    }
}

/// `resize` — applies a `TIOCSWINSZ`. The kernel delivers the `SIGWINCH`.
fn resize_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    if params.get("rows").is_none() {
        return failure(id, "rows must be 1..65535");
    }
    let Some(rows) = axis(params, "rows", 0) else {
        return failure(id, "rows must be 1..65535");
    };
    if params.get("cols").is_none() {
        return failure(id, "cols must be 1..65535");
    }
    let Some(cols) = axis(params, "cols", 0) else {
        return failure(id, "cols must be 1..65535");
    };
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    pane.resize(rows, cols);
    success(id, json!({}))
}

/// `spawn` — forks a standalone pane.
///
/// `rows`/`cols` default to 24×80 when absent, but a PRESENT value is range-checked first. The
/// Swift records why: a bare `UInt16(_:)` on a socket-supplied value trapped, and one bad NDJSON
/// line took down every session in the host.
fn spawn_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let Some(rows) = axis(params, "rows", i64::from(FALLBACK_GRID.0)) else {
        return failure(id, "rows must be 1..65535");
    };
    let Some(cols) = axis(params, "cols", i64::from(FALLBACK_GRID.1)) else {
        return failure(id, "cols must be 1..65535");
    };
    let cmd: Option<Vec<String>> = params.get("cmd").and_then(Value::as_array).map(|array| {
        array
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    });
    let env = params.get("env").and_then(Value::as_object);
    match host.spawn_standalone(cmd.as_deref(), text(params, "cwd"), env, rows, cols) {
        Ok(pane_id) => success(id, json!({ "paneId": pane_id })),
        Err(SpawnRefused(why)) => failure(id, &format!("spawn failed: {why}")),
    }
}

/// `report` — an agent self-declares its state, authoritatively.
///
/// Validate-then-drop: a missing `paneId`, an unknown pane, or a `state` outside the closed
/// supervision set is an error line and never a trap. The state is checked BEFORE the pane is
/// looked up, which is the Swift's order and the one the suite pins.
fn report_agent(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    if text(params, "paneId").is_none() {
        return failure(id, "missing params.paneId");
    }
    let Some(state) = text(params, "state") else {
        return failure(id, "missing params.state");
    };
    if !supervision::is_valid(state) {
        return failure(
            id,
            &format!("invalid state '{state}' (want one of: {})", vocabulary()),
        );
    }
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    pane.report_agent_status(state, text(params, "message"));
    success(id, json!({ "state": state }))
}

/// The supervision vocabulary, as an error message lists it.
fn vocabulary() -> String {
    supervision::ALL
        .iter()
        .map(|state| state.name())
        .collect::<Vec<_>>()
        .join(", ")
}

// ---------------------------------------------------------------------------------------------- //
// The two blocking verbs
// ---------------------------------------------------------------------------------------------- //

/// A one-shot parking spot: a tap on some other thread settles it, the connection thread waits for
/// it until a deadline.
///
/// One type for all three waits — `run --wait`, `wait --until` and `wait --state` — because they
/// differ only in what settles them, and the Swift wrote the same `NSCondition` dance out three
/// times. FIRST writer wins: a second block closing, or a second matching transition, does not
/// overwrite the answer already taken.
#[derive(Debug)]
struct Latch<T> {
    slot: std::sync::Mutex<Option<T>>,
    ready: std::sync::Condvar,
}

impl<T> Latch<T> {
    /// An unsettled latch.
    const fn new() -> Self {
        Self {
            slot: std::sync::Mutex::new(None),
            ready: std::sync::Condvar::new(),
        }
    }

    /// Settles it, unless it already was.
    ///
    /// A poisoned lock is taken anyway: the state behind it is one `Option`, a panic cannot have
    /// left it torn, and refusing to settle here would park the connection thread until its timeout
    /// for no reason a caller could act on.
    fn settle(&self, value: T) {
        let mut slot = self
            .slot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.is_none() {
            *slot = Some(value);
            // Released before the notify, not after: the settler is a TAP on the read loop, and
            // waking the connection thread while still holding the lock it is about to want hands
            // it straight back to a blocked acquire.
            drop(slot);
            self.ready.notify_all();
        }
    }

    /// Waits until it settles or `deadline` elapses, answering what settled it.
    fn settled_within(&self, deadline: std::time::Duration) -> Option<T> {
        let (mut slot, _) = self
            .ready
            .wait_timeout_while(
                self.slot
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner),
                deadline,
                |slot| slot.is_none(),
            )
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let settled = slot.take();
        drop(slot);
        settled
    }
}

/// Settles a latch when a block at or past `baseline` CLOSES.
#[derive(Debug)]
struct ClosedBlockTap {
    latch: Arc<Latch<BlockUpdate>>,
    baseline: u32,
}

impl BlockTap for ClosedBlockTap {
    fn updated(&self, update: &BlockUpdate) {
        // A CLOSED block carries `complete` (the `D` arrived) or a duration (an interrupted close —
        // Ctrl-C, a re-prompt without a `D`). A running block's emission carries neither.
        if update.index < self.baseline || !(update.complete || update.duration_ms.is_some()) {
            return;
        }
        self.latch.settle(update.clone());
    }
}

/// Settles a latch when the pane's output matches a pattern.
#[derive(Debug)]
struct MatchTap {
    latch: Arc<Latch<()>>,
    scanner: std::sync::Mutex<slopdesk_rowscan::waituntil::Scanner>,
}

impl OutputTap for MatchTap {
    fn chunk(&self, payload: &[u8]) {
        // On the READ LOOP: the scan is incremental and windowed, so this stays O(chunk). Feeding
        // the whole accumulated buffer here was O(n²) over a chatty command and visibly lagged the
        // pane it was watching.
        let mut scanner = self
            .scanner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if scanner.ingest(payload) {
            self.latch.settle(());
        }
    }
}

/// Settles a latch when ONE named pane enters one of a set of states.
#[derive(Debug)]
struct StateTap {
    latch: Arc<Latch<String>>,
    pane_id: String,
    targets: std::collections::BTreeSet<String>,
}

impl AgentStatusTap for StateTap {
    fn changed(&self, event: &AgentStatusEvent) {
        if event.pane_id == self.pane_id && self.targets.contains(&event.state) {
            self.latch.settle(event.state.clone());
        }
    }
}

/// `run` — injects `text` plus a carriage return, atomically.
///
/// With `wait: true` it BLOCKS until that command's OSC-133 block closes and answers with the
/// result — the herdr-style "run and give me the output" primitive. The command is identified by
/// block INDEX, snapshotted BEFORE the write, and the first close at or past it is the answer. An
/// interleaved second driver could race a command in between and the answer would be that one's;
/// one driver per pane is the supported shape.
fn run_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    if text(params, "paneId").is_none() {
        return failure(id, "missing params.paneId");
    }
    let Some(typed) = text(params, "text") else {
        return failure(id, "missing params.text");
    };
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    let mut bytes = typed.as_bytes().to_vec();
    bytes.push(b'\r');
    if !flag(params, "wait", false) {
        pane.write_raw(&bytes);
        return success(id, json!({}));
    }

    // `limit: 0` asks for the baseline and NOTHING else. A `run --wait` has no use for the previous
    // commands' bytes, and shipping them would be a quarter of a megabyte per call.
    let Some(baseline) = pane.blocks(0).and_then(|reply| reply.next_index) else {
        return failure(id, NO_BLOCK_TAP);
    };
    let stripped = flag(params, "ansiStrip", true);
    let latch = Arc::new(Latch::new());
    let token = pane.add_block_tap(Arc::new(ClosedBlockTap {
        latch: Arc::clone(&latch),
        baseline,
    }));

    // The write happens AFTER the tap is on, or a command that finishes instantly closes its block
    // into a pane nobody is watching.
    pane.write_raw(&bytes);
    let started = std::time::Instant::now();
    let closed = latch.settled_within(deadline(params));
    pane.remove_block_tap(token);

    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    let Some(closed) = closed else {
        return success(id, json!({ "matched": false, "elapsed": elapsed }));
    };
    let output = pane.block_output(closed.index).unwrap_or_default();
    let mut result = json!({
        "matched": true,
        "elapsed": elapsed,
        "blockIndex": closed.index,
        "output": block_text(&output, stripped),
    });
    if let Some(object) = result.as_object_mut() {
        if let Some(code) = closed.exit_code {
            object.insert("exitCode".to_owned(), Value::from(code));
        }
        if let Some(duration) = closed.duration_ms {
            object.insert("durationMs".to_owned(), Value::from(duration));
        }
    }
    success(id, result)
}

/// `wait` — blocks until the pane's output matches `until`, or its supervision state enters
/// `state`, or the deadline elapses. Exactly one of the two arguments must be present.
fn wait_pane(id: &str, params: &Map<String, Value>, host: &dyn ControlHost) -> String {
    let Some(pane_id) = text(params, "paneId") else {
        return failure(id, "missing params.paneId");
    };
    if let Some(spec) = text(params, "state") {
        return wait_for_state(id, pane_id, spec, params, host);
    }
    let Some(pattern) = text(params, "until") else {
        return failure(id, "missing params.until or params.state");
    };
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    // Compiled before the wait, not during it: this pattern arrived whole from an agent, so one that
    // does not compile must be reported rather than block silently until its timeout. The dialect is
    // the `regex` crate's — no lookaround, no backreferences.
    let Some(scanner) =
        slopdesk_rowscan::waituntil::Scanner::new(pattern, slopdesk_rowscan::waituntil::WAIT_BUFFER_CAP)
    else {
        return failure(id, &format!("invalid regex '{pattern}'"));
    };
    let latch = Arc::new(Latch::new());
    let token = pane.add_output_tap(Arc::new(MatchTap {
        latch: Arc::clone(&latch),
        scanner: std::sync::Mutex::new(scanner),
    }));
    let started = std::time::Instant::now();
    let matched = latch.settled_within(deadline(params)).is_some();
    pane.remove_output_tap(token);
    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    success(id, json!({ "matched": matched, "elapsed": elapsed }))
}

/// The `wait --state` arm: blocks until the pane's supervision state is in `spec`, a comma-set.
fn wait_for_state(
    id: &str,
    pane_id: &str,
    spec: &str,
    params: &Map<String, Value>,
    host: &dyn ControlHost,
) -> String {
    let targets: std::collections::BTreeSet<String> = spec
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .collect();
    if targets.is_empty() || !targets.iter().all(|name| supervision::is_valid(name)) {
        return failure(
            id,
            &format!("invalid state '{spec}' (want a comma-set of: {})", vocabulary()),
        );
    }
    let pane = match target(id, params, host) {
        Ok(pane) => pane,
        Err(refusal) => return refusal,
    };
    let latch = Arc::new(Latch::new());
    let token = host.add_status_tap(Arc::new(StateTap {
        latch: Arc::clone(&latch),
        pane_id: pane_id.to_owned(),
        targets: targets.clone(),
    }));
    // The current state is read AFTER the tap is on, and deliberately: the tap only sees FUTURE
    // transitions, so a pane that is ALREADY in a target state — or one that moved into it between
    // the lookup and the registration — would otherwise wait out the whole timeout for a transition
    // that had already happened.
    let (current, _) = pane.agent_status();
    if targets.contains(&current) {
        latch.settle(current);
    }
    let started = std::time::Instant::now();
    let matched = latch.settled_within(deadline(params));
    host.remove_status_tap(token);
    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    matched.map_or_else(
        || success(id, json!({ "matched": false, "elapsed": elapsed })),
        |state| success(id, json!({ "matched": true, "state": state, "elapsed": elapsed })),
    )
}
