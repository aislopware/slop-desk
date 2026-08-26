//! The agent-control verbs, driven against a pane that is only its answers.
//!
//! Two halves, matching the port's two modules. The dispatcher's tests hand
//! [`slopdesk_hostserver::control::dispatch`] one decoded request and read one line back — no
//! socket, no thread, no PTY. The connection's run the whole
//! [`slopdesk_hostserver::ctlserve::ControlConnections`] over a `socketpair(2)`, because the
//! framing and the subscribe pump are exactly what a request-shaped test cannot see.
//!
//! The fakes are the reason both are possible. `ControlHost` and `Pane` were carved so that
//! everything a verb decides is on one side of them and everything a verb OBSERVES is on the other,
//! and the sharpest assertion in this file depends on it: a refused verb must not so much as look
//! its pane up, which is only checkable when the lookup is something a test counts. The pane fake
//! is `support::Ghost`, shared with the registry and store suites — see that module for why there
//! is one of it rather than two.

#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]

use std::io::Read as _;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Map, Value, json};
use slopdesk_hostserver::Pane;
use slopdesk_hostserver::control::{
    AgentStatusEvent, AgentStatusTap, ControlHost, ControlRequest, IpcGuards, PaneRecord, SpawnRefused,
    dispatch, parse_request,
};
use slopdesk_hostserver::ctlserve::ControlConnections;
use slopdesk_hostsession::{BlockUpdate, TapToken};
use slopdesk_screenwire::payload::Snapshot;
use slopdesk_superwire::blockwire::ControlBlock;
use slopdesk_superwire::protocol::{BlocksReply, OpenBlock};

pub mod support;

use crate::support::{Ghost, Registered};

// ---------------------------------------------------------------------------------------------- //
// The fakes
// ---------------------------------------------------------------------------------------------- //

/// Overwrites one of the host fake's answer cells.
fn set<T>(cell: &Mutex<T>, value: T) {
    *cell.lock().unwrap_or_else(PoisonError::into_inner) = value;
}

/// One `spawn` as the host was asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct SpawnAsked {
    cmd: Option<Vec<String>>,
    cwd: Option<String>,
    rows: u16,
    cols: u16,
}

/// A host holding zero or one pane, counting every lookup.
///
/// The count is the point: "a refused verb never looked the pane up" is the guard order's whole
/// contract, and a lookup is observable to the caller — it is how one learns a pane exists.
#[derive(Debug)]
struct Host {
    pane: Option<Arc<Ghost>>,
    pane_id: String,
    lookups: AtomicUsize,
    kills: Mutex<Vec<String>>,
    killable: bool,
    spawn: Mutex<Result<String, SpawnRefused>>,
    spawned: Mutex<Vec<SpawnAsked>>,
    listed: Mutex<Vec<PaneRecord>>,
    status_taps: Registered<dyn AgentStatusTap>,
}

impl Host {
    fn empty() -> Arc<Self> {
        Arc::new(Self {
            pane: None,
            pane_id: String::from("p1"),
            lookups: AtomicUsize::new(0),
            kills: Mutex::new(Vec::new()),
            killable: true,
            spawn: Mutex::new(Ok(String::from("fresh"))),
            spawned: Mutex::new(Vec::new()),
            listed: Mutex::new(Vec::new()),
            status_taps: Registered::default(),
        })
    }

    fn holding(pane: &Arc<Ghost>) -> Arc<Self> {
        let mut host = Self::empty();
        Arc::get_mut(&mut host).unwrap().pane = Some(Arc::clone(pane));
        host
    }

    fn lookups(&self) -> usize {
        self.lookups.load(Ordering::SeqCst)
    }

    /// Fires every status tap, the way the cross-pane fan-out would.
    fn move_pane(&self, event: &AgentStatusEvent) {
        self.status_taps.each(|tap| tap.changed(event));
    }
}

impl ControlHost for Host {
    fn list_panes(&self) -> Vec<PaneRecord> {
        self.listed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn lookup_pane(&self, pane_id: &str) -> Option<Arc<dyn Pane>> {
        self.lookups.fetch_add(1, Ordering::SeqCst);
        if pane_id != self.pane_id {
            return None;
        }
        self.pane.as_ref().map(|pane| {
            let shared: Arc<Ghost> = Arc::clone(pane);
            let erased: Arc<dyn Pane> = shared;
            erased
        })
    }

    fn spawn_standalone(
        &self,
        cmd: Option<&[String]>,
        cwd: Option<&str>,
        _env: Option<&Map<String, Value>>,
        rows: u16,
        cols: u16,
    ) -> Result<String, SpawnRefused> {
        self.spawned
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(SpawnAsked {
                cmd: cmd.map(<[String]>::to_vec),
                cwd: cwd.map(str::to_owned),
                rows,
                cols,
            });
        self.spawn.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn kill_pane(&self, pane_id: &str) -> bool {
        self.kills
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(pane_id.to_owned());
        self.killable && pane_id == self.pane_id
    }

    fn add_status_tap(&self, tap: Arc<dyn AgentStatusTap>) -> TapToken {
        self.status_taps.add(tap)
    }

    fn remove_status_tap(&self, token: TapToken) {
        self.status_taps.remove(token);
    }
}

// ---------------------------------------------------------------------------------------------- //
// Driving one verb
// ---------------------------------------------------------------------------------------------- //

/// Dispatches `method` with `params` under fully permissive guards and a `zsh` foreground.
fn ask(host: &dyn ControlHost, method: &str, params: &Value) -> Value {
    ask_guarded(host, method, params, IpcGuards::permissive(), "zsh")
}

/// The general form: the guards and the foreground name are the two things a gate test moves.
fn ask_guarded(
    host: &dyn ControlHost,
    method: &str,
    params: &Value,
    guards: IpcGuards,
    foreground: &str,
) -> Value {
    let params = params.as_object().cloned().unwrap_or_default();
    let request = ControlRequest {
        id: String::from("r1"),
        method: method.to_owned(),
        params,
    };
    let name = |_: &dyn ControlHost, _: &str| foreground.to_owned();
    let line = dispatch(&request, host, guards, &name);
    assert!(line.ends_with('\n'), "every answer is one framed line: {line:?}");
    serde_json::from_str(&line).expect("an answer is JSON")
}

/// The `error` field of a refusal.
fn refusal(answer: &Value) -> &str {
    assert_eq!(answer["ok"], json!(false), "expected a refusal: {answer}");
    answer["error"].as_str().expect("a refusal carries text")
}

/// The `result` object of a success.
fn result(answer: &Value) -> &Value {
    assert_eq!(answer["ok"], json!(true), "expected a success: {answer}");
    &answer["result"]
}

fn pane_params() -> Value {
    json!({ "paneId": "p1" })
}

// ---------------------------------------------------------------------------------------------- //
// The line grammar
// ---------------------------------------------------------------------------------------------- //

#[test]
fn a_line_that_is_not_a_request_object_is_dropped_rather_than_refused() {
    // There is no `id` to address a refusal to, which is the whole reason these are silent.
    assert!(parse_request("not json").is_none(), "not JSON");
    assert!(parse_request("[1,2,3]").is_none(), "not an object");
    assert!(parse_request(r#"{"method":"read"}"#).is_none(), "no id");
    assert!(parse_request(r#"{"id":"a"}"#).is_none(), "no method");
    assert!(
        parse_request(r#"{"id":1,"method":"read"}"#).is_none(),
        "id is not a string"
    );
}

#[test]
fn an_absent_params_decodes_to_an_empty_map_rather_than_an_error() {
    let request = parse_request(r#"{"id":"a","method":"list-panes"}"#).expect("a valid request");
    assert!(
        request.params.is_empty(),
        "no params is no arguments, not a malformed line"
    );

    // A `params` of the wrong TYPE reads the same way: the verb below it refuses on the argument it
    // wanted, which is a better message than "params must be an object".
    let typed = parse_request(r#"{"id":"a","method":"read","params":7}"#).expect("still a request");
    assert!(typed.params.is_empty(), "a non-object params is no arguments");
}

#[test]
fn an_empty_result_is_omitted_and_the_keys_come_out_sorted() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "write", &json!({ "paneId": "p1", "text": "x" }));
    assert_eq!(answer["ok"], json!(true));
    assert!(
        answer.get("result").is_none(),
        "an empty result is omitted, not sent as {{}}"
    );

    // `serde_json`'s map is a `BTreeMap`, so this ordering is structural rather than incidental —
    // it is what makes a Rust-served line and a Swift `sortedKeys` one the same bytes.
    let request = ControlRequest {
        id: String::from("r1"),
        method: String::from("kill"),
        params: Map::new(),
    };
    let name = |_: &dyn ControlHost, _: &str| String::from("zsh");
    let line = dispatch(&request, host.as_ref(), IpcGuards::permissive(), &name);
    assert_eq!(
        line,
        "{\"error\":\"missing params.paneId\",\"id\":\"r1\",\"ok\":false}\n"
    );
}

#[test]
fn an_unknown_method_is_named_back() {
    let host = Host::empty();
    let answer = ask(host.as_ref(), "teleport", &json!({}));
    assert_eq!(refusal(&answer), "unknown method: teleport");
    assert_eq!(host.lookups(), 0, "an unknown verb has no pane to look up");
}

// ---------------------------------------------------------------------------------------------- //
// The guards, and the order they run in
// ---------------------------------------------------------------------------------------------- //

#[test]
fn a_mutating_verb_is_refused_before_the_pane_is_ever_looked_up() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    for method in ["write", "run", "spawn", "kill", "resize"] {
        let answer = ask_guarded(
            host.as_ref(),
            method,
            &json!({ "paneId": "p1", "text": "x", "rows": 24, "cols": 80 }),
            IpcGuards::default(),
            "zsh",
        );
        assert_eq!(refusal(&answer), "ipc send-keys disabled", "{method}");
    }
    assert_eq!(
        host.lookups(),
        0,
        "a refused verb must not answer 'does this pane exist'"
    );
    assert!(pane.written().is_empty(), "and must not reach the PTY");
}

#[test]
fn a_read_only_verb_runs_with_every_guard_shut() {
    let pane = Ghost::numbered(7);
    pane.set_scrollback("visible");
    let host = Host::holding(&pane);
    let answer = ask_guarded(host.as_ref(), "read", &pane_params(), IpcGuards::default(), "zsh");
    assert_eq!(result(&answer)["text"], json!("visible"));
}

#[test]
fn a_named_pane_running_a_sensitive_program_is_refused_by_name() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let guards = IpcGuards {
        allow_send_keys: true,
        allow_sensitive_sessions: false,
    };
    let answer = ask_guarded(
        host.as_ref(),
        "write",
        &json!({ "paneId": "p1", "text": "rm -rf /\r" }),
        guards,
        "ssh",
    );
    assert_eq!(refusal(&answer), "ipc sensitive-session blocked: ssh");
    assert!(pane.written().is_empty(), "the refusal is before the write");
}

#[test]
fn spawn_names_no_pane_so_only_the_send_keys_gate_stands_in_front_of_it() {
    let host = Host::empty();
    let guards = IpcGuards {
        allow_send_keys: true,
        allow_sensitive_sessions: false,
    };
    // `ssh` everywhere, and it does not matter: a fresh pane has no foreground process to be
    // sensitive about, so the gate that reads one has nothing to read.
    let answer = ask_guarded(host.as_ref(), "spawn", &json!({}), guards, "ssh");
    assert_eq!(result(&answer)["paneId"], json!("fresh"));
}

// ---------------------------------------------------------------------------------------------- //
// `list-panes`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn an_unknown_pane_field_is_omitted_rather_than_fabricated() {
    let host = Host::empty();
    Host::listed(&host).push(PaneRecord {
        pane_id: String::from("bare"),
        title: String::from("zsh"),
        pid: 42,
        is_alive: true,
        state: String::from("idle"),
        command: String::from("zsh"),
        rows: 24,
        cols: 80,
        cwd: None,
        last_exit_code: None,
        state_message: None,
    });
    Host::listed(&host).push(PaneRecord {
        pane_id: String::from("full"),
        title: String::from("build"),
        pid: 43,
        is_alive: false,
        state: String::from("done"),
        command: String::from("cargo"),
        rows: 30,
        cols: 100,
        cwd: Some(String::from("/tmp")),
        last_exit_code: Some(0),
        state_message: Some(String::from("built")),
    });

    let answer = ask(host.as_ref(), "list-panes", &json!({}));
    let panes = result(&answer)["panes"].as_array().expect("an array").clone();
    assert_eq!(panes.len(), 2);

    // JSON has no distinct "unset", and an agent reading a fabricated `""` or `0` as truth is worse
    // off than one told nothing.
    assert!(panes[0].get("cwd").is_none(), "an unknown cwd is absent");
    assert!(panes[0].get("lastExitCode").is_none(), "no command has finished");
    assert!(panes[0].get("stateMessage").is_none(), "nobody reported a label");
    assert_eq!(panes[0]["pid"], json!(42));
    assert_eq!(panes[0]["isAlive"], json!(true));

    assert_eq!(panes[1]["cwd"], json!("/tmp"));
    assert_eq!(
        panes[1]["lastExitCode"],
        json!(0),
        "a zero exit is a REPORTED zero"
    );
    assert_eq!(panes[1]["stateMessage"], json!("built"));
}

impl Host {
    /// The listing a `list-panes` will answer with, for a test to fill.
    fn listed(host: &Arc<Self>) -> std::sync::MutexGuard<'_, Vec<PaneRecord>> {
        host.listed.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

// ---------------------------------------------------------------------------------------------- //
// `read`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn a_verb_that_names_no_pane_is_told_which_argument_is_missing() {
    let host = Host::empty();
    for method in [
        "read",
        "screen",
        "last-output",
        "write",
        "run",
        "wait",
        "kill",
        "report",
    ] {
        let answer = ask(host.as_ref(), method, &json!({}));
        assert!(
            refusal(&answer).starts_with("missing params."),
            "{method} named its missing argument: {answer}"
        );
    }
}

#[test]
fn a_pane_that_is_not_there_is_named_in_the_refusal() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "read", &json!({ "paneId": "ghost" }));
    assert_eq!(refusal(&answer), "pane not found: ghost");
}

#[test]
fn read_strips_ansi_by_default_and_keeps_it_when_asked() {
    let pane = Ghost::numbered(7);
    pane.set_scrollback("hello");
    let host = Host::holding(&pane);

    let stripped = ask(host.as_ref(), "read", &pane_params());
    assert_eq!(
        result(&stripped)["text"],
        json!("hello"),
        "the default is stripped"
    );

    let raw = ask(
        host.as_ref(),
        "read",
        &json!({ "paneId": "p1", "ansiStrip": false }),
    );
    assert_eq!(
        result(&raw)["text"],
        json!("raw:hello"),
        "asking for the escapes gets them"
    );
}

#[test]
fn read_unwrapped_answers_logical_lines_and_caps_them() {
    let pane = Ghost::numbered(7);
    pane.set_lines(vec![
        String::from("one"),
        String::from("two"),
        String::from("three"),
    ]);
    let host = Host::holding(&pane);

    let all = ask(
        host.as_ref(),
        "read",
        &json!({ "paneId": "p1", "source": "unwrapped" }),
    );
    assert_eq!(result(&all)["lines"], json!(["one", "two", "three"]));
    assert_eq!(result(&all)["text"], json!("one\ntwo\nthree"));

    // `recent` is the older spelling of the same source, and both still answer.
    let capped = ask(
        host.as_ref(),
        "read",
        &json!({ "paneId": "p1", "source": "recent", "lines": 2 }),
    );
    assert_eq!(result(&capped)["lines"], json!(["two", "three"]), "the LAST n");

    // A non-positive cap is no cap rather than an error — an agent that computed a zero gets the
    // whole buffer, which is what it would have got by omitting the argument.
    let zero = ask(
        host.as_ref(),
        "read",
        &json!({ "paneId": "p1", "source": "unwrapped", "lines": 0 }),
    );
    assert_eq!(result(&zero)["lines"], json!(["one", "two", "three"]));
}

// ---------------------------------------------------------------------------------------------- //
// `screen`
// ---------------------------------------------------------------------------------------------- //

fn grid(lines: &[&str]) -> Snapshot {
    Snapshot {
        rows: 0,
        cols: 0,
        cursor_row: 2,
        cursor_col: 5,
        cursor_visible: true,
        alt_screen: false,
        lines: lines.iter().map(|line| (*line).to_owned()).collect(),
    }
}

#[test]
fn screen_defaults_to_the_panes_live_grid_and_falls_back_when_the_pty_is_gone() {
    let pane = Ghost::numbered(7);
    pane.set_screen(Ok(grid(&["a"])));
    let host = Host::holding(&pane);

    let live = ask(host.as_ref(), "screen", &pane_params());
    assert_eq!(
        result(&live)["rows"],
        json!(30),
        "the LIVE TIOCGWINSZ, not the negotiated grid"
    );
    assert_eq!(result(&live)["cols"], json!(100));

    pane.set_window(None);
    let gone = ask(host.as_ref(), "screen", &pane_params());
    assert_eq!(
        result(&gone)["rows"],
        json!(24),
        "24x80 when there is nothing to measure"
    );
    assert_eq!(result(&gone)["cols"], json!(80));
}

#[test]
fn a_screen_axis_outside_the_models_clamp_is_refused_rather_than_clamped() {
    let pane = Ghost::numbered(7);
    pane.set_screen(Ok(grid(&["a"])));
    let host = Host::holding(&pane);

    for rows in [0, 513, -1, 1_000_000] {
        let answer = ask(host.as_ref(), "screen", &json!({ "paneId": "p1", "rows": rows }));
        assert_eq!(refusal(&answer), "rows must be 1..512", "rows {rows}");
    }
    for cols in [0, 1025, -1] {
        let answer = ask(host.as_ref(), "screen", &json!({ "paneId": "p1", "cols": cols }));
        assert_eq!(refusal(&answer), "cols must be 1..1024", "cols {cols}");
    }

    let ok = ask(
        host.as_ref(),
        "screen",
        &json!({ "paneId": "p1", "rows": 10, "cols": 40 }),
    );
    assert_eq!(result(&ok)["rows"], json!(10));
    assert_eq!(result(&ok)["cols"], json!(40));
}

#[test]
fn screen_drops_the_trailing_blank_rows_from_its_text_but_not_from_its_lines() {
    let pane = Ghost::numbered(7);
    pane.set_screen(Ok(grid(&["top", "", "bottom", "", "   "])));
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "screen", &pane_params());

    assert_eq!(result(&answer)["text"], json!("top\n\nbottom"));
    assert_eq!(
        result(&answer)["lines"],
        json!(["top", "", "bottom", "", "   "]),
        "the grid itself is answered whole — the trim is the convenience field's"
    );
    assert_eq!(result(&answer)["cursorRow"], json!(2));
    assert_eq!(result(&answer)["cursorVisible"], json!(true));
    assert_eq!(result(&answer)["altScreen"], json!(false));
}

#[test]
fn a_screen_engine_that_is_not_there_is_answered_rather_than_faked() {
    let pane = Ghost::numbered(7);
    pane.set_screen(Err(String::from("connect refused")));
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "screen", &pane_params());
    // `read` is one verb away for the raw bytes, and a synthesised grid would be a lie about what
    // the pane shows.
    assert_eq!(refusal(&answer), "screen engine unavailable: connect refused");
}

// ---------------------------------------------------------------------------------------------- //
// `last-output`
// ---------------------------------------------------------------------------------------------- //

fn closed_block(index: u32, command: &str, output: &[u8], exit: Option<i32>) -> ControlBlock {
    ControlBlock {
        index,
        command_text: command.to_owned(),
        exit_code: exit,
        duration_ms: exit.map(|_| 12),
        complete: true,
        output: output.to_vec(),
    }
}

#[test]
fn a_pane_with_no_segmenter_says_so_in_one_sentence_both_block_verbs_share() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let expected = "no block tap on this pane (SLOPDESK_BLOCKS=0, or it has no shell integration)";

    let read = ask(host.as_ref(), "last-output", &pane_params());
    assert_eq!(refusal(&read), expected);

    // A caller keys its fallback to `read` on this exact text, so the two verbs must not drift.
    let run = ask(
        host.as_ref(),
        "run",
        &json!({ "paneId": "p1", "text": "ls", "wait": true, "timeoutMs": 50 }),
    );
    assert_eq!(refusal(&run), expected);
}

#[test]
fn last_output_carries_the_optional_block_fields_only_when_they_exist() {
    let pane = Ghost::numbered(7);
    pane.set_blocks(Some(BlocksReply {
        recent: Some(vec![
            closed_block(1, "true", b"done\n", Some(0)),
            closed_block(2, "sleep 1", b"", None),
        ]),
        open: Some(OpenBlock {
            command_text: String::from("tail -f log"),
            output_len: 4096,
        }),
        ..BlocksReply::empty()
    }));
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "last-output", &json!({ "paneId": "p1", "n": 2 }));
    let blocks = result(&answer)["blocks"].as_array().expect("an array").clone();

    assert_eq!(blocks[0]["exitCode"], json!(0), "a reported zero is a value");
    assert_eq!(blocks[0]["durationMs"], json!(12));
    assert_eq!(blocks[0]["output"], json!("done\n"));
    assert_eq!(blocks[0]["complete"], json!(true));
    assert!(blocks[1].get("exitCode").is_none(), "no `$?` was reported");
    assert!(blocks[1].get("durationMs").is_none());

    // The running block's LENGTH and command, never its bytes: a `last-output` under `tail -f`
    // would otherwise ship a quarter of a megabyte to answer a question about the commands before.
    assert_eq!(result(&answer)["running"]["command"], json!("tail -f log"));
    assert_eq!(result(&answer)["running"]["outputLen"], json!(4096));
}

// ---------------------------------------------------------------------------------------------- //
// `write`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn write_wants_one_of_text_and_keys() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "write", &json!({ "paneId": "p1" }));
    assert_eq!(refusal(&answer), "missing params.text or params.keys");

    let empty_keys = ask(host.as_ref(), "write", &json!({ "paneId": "p1", "keys": [] }));
    assert_eq!(refusal(&empty_keys), "missing params.text or params.keys");
}

#[test]
fn an_unknown_key_token_rejects_the_whole_request_and_sends_nothing() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "write",
        &json!({ "paneId": "p1", "text": "yes", "keys": ["Enter", "Warp"] }),
    );
    assert_eq!(refusal(&answer), "unknown key: Warp");
    // Half of `Enter Warp` is an instruction the caller never gave — validate-then-drop, and the
    // drop is the whole sequence.
    assert!(pane.written().is_empty(), "not one byte of a rejected sequence");
}

#[test]
fn write_sends_the_text_first_then_each_key_in_order() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "write",
        &json!({ "paneId": "p1", "text": "ls", "keys": ["Enter"] }),
    );
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(pane.written(), b"ls\r".to_vec());
}

// ---------------------------------------------------------------------------------------------- //
// `run`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn run_without_wait_types_the_command_and_returns() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "run", &json!({ "paneId": "p1", "text": "make" }));
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(
        pane.written(),
        b"make\r".to_vec(),
        "the CR is the run, atomically"
    );
}

#[test]
fn run_with_wait_answers_the_block_that_closed_at_or_past_its_baseline() {
    let pane = Ghost::numbered(7);
    pane.set_blocks(Some(BlocksReply {
        next_index: Some(9),
        ..BlocksReply::empty()
    }));
    pane.set_block_output(9, b"hello\n".to_vec());
    let host = Host::holding(&pane);

    let watcher = Arc::clone(&pane);
    let closer = std::thread::spawn(move || {
        // Wait for the tap to be installed — the dispatcher registers it BEFORE the write, so a
        // command that finishes instantly still closes into a pane somebody is watching.
        while watcher.block_taps() == 0 {
            std::thread::yield_now();
        }
        watcher.publish(&BlockUpdate {
            index: 8,
            command_text: String::from("stale"),
            exit_code: Some(1),
            duration_ms: Some(3),
            complete: true,
        });
        watcher.publish(&BlockUpdate {
            index: 9,
            command_text: String::from("echo hello"),
            exit_code: Some(0),
            duration_ms: Some(21),
            complete: true,
        });
    });

    let answer = ask(
        host.as_ref(),
        "run",
        &json!({ "paneId": "p1", "text": "echo hello", "wait": true, "timeoutMs": 5000 }),
    );
    closer.join().expect("the closer thread");

    assert_eq!(result(&answer)["matched"], json!(true));
    assert_eq!(
        result(&answer)["blockIndex"],
        json!(9),
        "the one at the baseline, not the one before"
    );
    assert_eq!(result(&answer)["output"], json!("hello\n"));
    assert_eq!(result(&answer)["exitCode"], json!(0));
    assert_eq!(result(&answer)["durationMs"], json!(21));
    assert_eq!(pane.block_taps(), 0, "the tap is retired whatever the outcome");
}

#[test]
fn run_with_wait_that_times_out_answers_unmatched_rather_than_failing() {
    let pane = Ghost::numbered(7);
    pane.set_blocks(Some(BlocksReply {
        next_index: Some(1),
        ..BlocksReply::empty()
    }));
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "run",
        &json!({ "paneId": "p1", "text": "sleep 60", "wait": true, "timeoutMs": 25 }),
    );
    // The command WAS typed and is still running; "we did not see it finish" is a different fact
    // from "the call failed", and an orchestrator acts on them differently.
    assert_eq!(result(&answer)["matched"], json!(false));
    assert_eq!(pane.written(), b"sleep 60\r".to_vec());
    assert_eq!(pane.block_taps(), 0);
}

#[test]
fn a_still_running_block_does_not_settle_a_run_wait() {
    let pane = Ghost::numbered(7);
    pane.set_blocks(Some(BlocksReply {
        next_index: Some(4),
        ..BlocksReply::empty()
    }));
    let host = Host::holding(&pane);

    let watcher = Arc::clone(&pane);
    let noise = std::thread::spawn(move || {
        while watcher.block_taps() == 0 {
            std::thread::yield_now();
        }
        // A RUNNING block's emission carries neither `complete` nor a duration; only a close does.
        watcher.publish(&BlockUpdate {
            index: 4,
            command_text: String::from("slow"),
            exit_code: None,
            duration_ms: None,
            complete: false,
        });
    });

    let answer = ask(
        host.as_ref(),
        "run",
        &json!({ "paneId": "p1", "text": "slow", "wait": true, "timeoutMs": 60 }),
    );
    noise.join().expect("the noise thread");
    assert_eq!(
        result(&answer)["matched"],
        json!(false),
        "a running block is not a finished one"
    );
}

// ---------------------------------------------------------------------------------------------- //
// `wait`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn wait_wants_one_of_until_and_state() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(host.as_ref(), "wait", &pane_params());
    assert_eq!(refusal(&answer), "missing params.until or params.state");
}

#[test]
fn a_pattern_that_does_not_compile_is_reported_rather_than_waited_out() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "wait",
        &json!({ "paneId": "p1", "until": "(unclosed", "timeoutMs": 60_000 }),
    );
    // The alternative is blocking silently for the whole deadline on a pattern that could never
    // match, which is indistinguishable from a command that never printed.
    assert_eq!(refusal(&answer), "invalid regex '(unclosed'");
    assert_eq!(pane.output_taps(), 0, "nothing was installed");
}

#[test]
fn wait_until_settles_on_a_chunk_that_matches_and_retires_its_tap() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);

    let writer = Arc::clone(&pane);
    let feeder = std::thread::spawn(move || {
        while writer.output_taps() == 0 {
            std::thread::yield_now();
        }
        writer.emit(b"building...\n");
        writer.emit(b"BUILD SUCCEEDED\n");
    });

    let answer = ask(
        host.as_ref(),
        "wait",
        &json!({ "paneId": "p1", "until": "BUILD (SUCCEEDED|FAILED)", "timeoutMs": 5000 }),
    );
    feeder.join().expect("the feeder thread");
    assert_eq!(result(&answer)["matched"], json!(true));
    assert_eq!(pane.output_taps(), 0);
}

#[test]
fn wait_until_that_never_matches_answers_unmatched_with_its_elapsed() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "wait",
        &json!({ "paneId": "p1", "until": "never", "timeoutMs": 25 }),
    );
    assert_eq!(result(&answer)["matched"], json!(false));
    assert!(
        result(&answer)["elapsed"].as_f64().expect("a number") >= 0.0,
        "an elapsed is always reported"
    );
}

#[test]
fn wait_state_wants_a_comma_set_from_the_closed_supervision_vocabulary() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    for spec in ["", "  ", "running", "idle,running"] {
        let answer = ask(
            host.as_ref(),
            "wait",
            &json!({ "paneId": "p1", "state": spec, "timeoutMs": 25 }),
        );
        assert!(
            refusal(&answer).starts_with(&format!("invalid state '{spec}'")),
            "{spec}: {answer}"
        );
    }
}

#[test]
fn a_pane_already_in_a_target_state_settles_without_waiting_for_a_transition() {
    let pane = Ghost::numbered(7);
    pane.set_status("blocked", Some("needs you"));
    let host = Host::holding(&pane);
    // A tap only ever sees FUTURE transitions. Without the read-after-register this would wait out
    // its whole timeout for a move that had already happened.
    let answer = ask(
        host.as_ref(),
        "wait",
        &json!({ "paneId": "p1", "state": "blocked, done", "timeoutMs": 60_000 }),
    );
    assert_eq!(result(&answer)["matched"], json!(true));
    assert_eq!(result(&answer)["state"], json!("blocked"));
    assert_eq!(host.status_taps.count(), 0, "the tap is retired");
}

#[test]
fn wait_state_settles_on_a_transition_of_the_named_pane_only() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);

    let mover = Arc::clone(&host);
    let feeder = std::thread::spawn(move || {
        while mover.status_taps.count() == 0 {
            std::thread::yield_now();
        }
        // Another pane reaching the target state must not settle this wait.
        mover.move_pane(&AgentStatusEvent {
            pane_id: String::from("elsewhere"),
            state: String::from("done"),
            agent_present: true,
            title: String::from("other"),
            ts: 1,
        });
        mover.move_pane(&AgentStatusEvent {
            pane_id: String::from("p1"),
            state: String::from("working"),
            agent_present: true,
            title: String::from("mine"),
            ts: 2,
        });
        mover.move_pane(&AgentStatusEvent {
            pane_id: String::from("p1"),
            state: String::from("done"),
            agent_present: true,
            title: String::from("mine"),
            ts: 3,
        });
    });

    let answer = ask(
        host.as_ref(),
        "wait",
        &json!({ "paneId": "p1", "state": "done", "timeoutMs": 5000 }),
    );
    feeder.join().expect("the feeder thread");
    assert_eq!(result(&answer)["matched"], json!(true));
    assert_eq!(result(&answer)["state"], json!("done"));
}

// ---------------------------------------------------------------------------------------------- //
// `spawn`, `kill`, `resize`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn spawn_defaults_its_grid_but_range_checks_a_present_one() {
    let host = Host::empty();

    let defaulted = ask(
        host.as_ref(),
        "spawn",
        &json!({ "cmd": ["zsh", "-l"], "cwd": "/tmp" }),
    );
    assert_eq!(result(&defaulted)["paneId"], json!("fresh"));
    let asked = host
        .spawned
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    assert_eq!(asked[0].rows, 24, "24x80 when the caller said nothing");
    assert_eq!(asked[0].cols, 80);
    assert_eq!(asked[0].cmd, Some(vec![String::from("zsh"), String::from("-l")]));
    assert_eq!(asked[0].cwd, Some(String::from("/tmp")));

    // The Swift records why this is a refusal and not a conversion: a bare `UInt16(_:)` on a
    // socket-supplied value trapped, and one bad NDJSON line took down every session in the host.
    for rows in [0, -1, 65_536] {
        let answer = ask(host.as_ref(), "spawn", &json!({ "rows": rows }));
        assert_eq!(refusal(&answer), "rows must be 1..65535", "rows {rows}");
    }
    let cols = ask(host.as_ref(), "spawn", &json!({ "cols": 70_000 }));
    assert_eq!(refusal(&cols), "cols must be 1..65535");
}

#[test]
fn a_refused_spawn_carries_the_reason_it_was_given() {
    let host = Host::empty();
    set(&host.spawn, Err(SpawnRefused(String::from("no such directory"))));
    let answer = ask(host.as_ref(), "spawn", &json!({}));
    assert_eq!(refusal(&answer), "spawn failed: no such directory");
}

#[test]
fn kill_answers_whether_a_pane_was_there() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);

    let hit = ask(host.as_ref(), "kill", &pane_params());
    assert_eq!(hit["ok"], json!(true));

    let miss = ask(host.as_ref(), "kill", &json!({ "paneId": "ghost" }));
    assert_eq!(refusal(&miss), "pane not found: ghost");
}

#[test]
fn resize_wants_both_axes_and_refuses_either_one_out_of_range() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);

    assert_eq!(
        refusal(&ask(
            host.as_ref(),
            "resize",
            &json!({ "paneId": "p1", "cols": 80 })
        )),
        "rows must be 1..65535"
    );
    assert_eq!(
        refusal(&ask(
            host.as_ref(),
            "resize",
            &json!({ "paneId": "p1", "rows": 24 })
        )),
        "cols must be 1..65535"
    );
    assert_eq!(
        refusal(&ask(
            host.as_ref(),
            "resize",
            &json!({ "paneId": "p1", "rows": 24, "cols": 0 })
        )),
        "cols must be 1..65535"
    );

    let ok = ask(
        host.as_ref(),
        "resize",
        &json!({ "paneId": "p1", "rows": 50, "cols": 132 }),
    );
    assert_eq!(ok["ok"], json!(true));
    assert_eq!(
        pane.resized(),
        vec![(50, 132)],
        "rows first — the control verb's spelling, not the size fold's"
    );
}

// ---------------------------------------------------------------------------------------------- //
// `report`
// ---------------------------------------------------------------------------------------------- //

#[test]
fn an_invalid_state_is_refused_before_the_pane_is_looked_up() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "report",
        &json!({ "paneId": "p1", "state": "confused" }),
    );
    assert!(
        refusal(&answer).starts_with("invalid state 'confused' (want one of: "),
        "{answer}"
    );
    assert!(
        refusal(&answer).contains("blocked"),
        "the vocabulary is listed: {answer}"
    );
    assert_eq!(
        host.lookups(),
        0,
        "the validation is the Swift's order, and it is first"
    );
}

#[test]
fn a_valid_report_reaches_the_pane_with_its_label() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "report",
        &json!({ "paneId": "p1", "state": "blocked", "message": "waiting on review" }),
    );
    assert_eq!(result(&answer)["state"], json!("blocked"));
    assert_eq!(pane.reported(), vec![(
        String::from("blocked"),
        Some(String::from("waiting on review"))
    )]);
}

#[test]
fn a_message_of_the_wrong_type_is_ignored_rather_than_refused() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let answer = ask(
        host.as_ref(),
        "report",
        &json!({ "paneId": "p1", "state": "done", "message": 7 }),
    );
    assert_eq!(result(&answer)["state"], json!("done"));
    assert_eq!(
        pane.reported()[0].1.clone(),
        None,
        "the label is optional, so a bad one is an absent one"
    );
}

// ---------------------------------------------------------------------------------------------- //
// The connection: framing, refusals, and the two subscribe modes
// ---------------------------------------------------------------------------------------------- //

/// One connected pair, with the SERVER end already being served.
struct Wire {
    client: OwnedFd,
}

impl Wire {
    fn to(host: Arc<Host>) -> Self {
        Self::guarded(host, IpcGuards::permissive())
    }

    fn guarded(host: Arc<Host>, guards: IpcGuards) -> Self {
        use nix::sys::socket::{AddressFamily, SockFlag, SockType, socketpair};
        let (client, server) =
            socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty()).expect("a socketpair");
        ControlConnections::with_guards(host, guards).serve(server);
        Self { client }
    }

    fn send(&self, bytes: &[u8]) {
        nix::unistd::write(&self.client, bytes).expect("a write to a live peer");
    }

    /// Reads until `count` newline-terminated lines have arrived, then answers them.
    ///
    /// Line-counted rather than byte-counted because the pump writes when it has something and a
    /// reader that asked for a fixed number of bytes would block on whichever boundary it guessed
    /// wrong.
    fn lines(&self, count: usize) -> Vec<Value> {
        let mut file = std::fs::File::from(self.client.try_clone().expect("a clone of the client end"));
        let mut buffer = Vec::new();
        let mut chunk = [0_u8; 512];
        let mut seen = 0;
        while seen < count {
            let read = file.read(&mut chunk).expect("a read from a live peer");
            if read == 0 {
                break;
            }
            let landed = &chunk[..read];
            for byte in landed {
                if *byte == b'\n' {
                    seen += 1;
                }
            }
            buffer.extend_from_slice(landed);
        }
        String::from_utf8_lossy(&buffer)
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_str(line).expect("every line is JSON"))
            .collect()
    }

    /// Hangs up, which is how a subscriber's pump is meant to end.
    fn hang_up(self) {
        drop(self.client);
    }
}

#[test]
fn two_requests_in_one_write_are_answered_as_two_lines() {
    let pane = Ghost::numbered(7);
    pane.set_scrollback("hi");
    let wire = Wire::to(Host::holding(&pane));
    wire.send(b"{\"id\":\"a\",\"method\":\"read\",\"params\":{\"paneId\":\"p1\"}}\n{\"id\":\"b\",\"method\":\"list-panes\"}\n");

    let answers = wire.lines(2);
    assert_eq!(answers[0]["id"], json!("a"));
    assert_eq!(answers[0]["result"]["text"], json!("hi"));
    assert_eq!(answers[1]["id"], json!("b"));
    assert_eq!(answers[1]["result"]["panes"], json!([]));
}

#[test]
fn a_blank_line_is_answered_with_silence_and_the_next_request_still_lands() {
    let wire = Wire::to(Host::empty());
    // No `id` to address a refusal to — so there is nothing truthful to send back.
    wire.send(b"\n   \n{\"id\":\"a\",\"method\":\"list-panes\"}\n");
    let answers = wire.lines(1);
    assert_eq!(
        answers.len(),
        1,
        "exactly one answer for three lines: {answers:?}"
    );
    assert_eq!(answers[0]["id"], json!("a"));
}

#[test]
fn a_line_that_is_not_utf8_is_refused_rather_than_lossily_repaired() {
    let wire = Wire::to(Host::empty());
    wire.send(b"{\"id\":\"a\",\"method\":\"\xff\xfe\"}\n");
    let answers = wire.lines(1);
    // A repaired verb or pane id would name something the caller did not ask for.
    assert_eq!(answers[0]["error"], json!("invalid UTF-8"));
    assert_eq!(answers[0]["id"], json!("?"), "there is no id to echo");
}

#[test]
fn a_line_past_the_cap_is_refused_with_the_cap_both_ends_of_the_socket_read() {
    let wire = Wire::to(Host::empty());
    let mut line = Vec::from(b"{\"id\":\"a\",\"method\":\"read\",\"params\":{\"paneId\":\"".as_slice());
    line.extend(std::iter::repeat_n(
        b'x',
        slopdesk_workspace::control_request::MAX_REQUEST_BYTES,
    ));
    line.extend_from_slice(b"\"}}\n");
    wire.send(&line);
    let answers = wire.lines(1);
    assert_eq!(answers[0]["error"], json!("request too large"));
}

#[test]
fn a_malformed_request_line_is_refused_with_no_id_to_echo() {
    let wire = Wire::to(Host::empty());
    wire.send(b"{not json}\n");
    let answers = wire.lines(1);
    assert_eq!(answers[0]["error"], json!("malformed request"));
    assert_eq!(answers[0]["ok"], json!(false));
}

#[test]
fn subscribe_streams_a_panes_output_then_one_closed_when_it_ends() {
    let pane = Ghost::numbered(7);
    let host = Host::holding(&pane);
    let wire = Wire::to(Arc::clone(&host));
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"p1\"}}\n");

    while pane.output_taps() == 0 {
        std::thread::yield_now();
    }
    // The ANSI is stripped by default: a subscriber is an agent reading text.
    pane.emit(b"\x1b[32mgreen\x1b[0m\n");
    pane.emit(b"second\n");
    pane.end();

    let events = wire.lines(3);
    assert_eq!(events[0], json!({ "event": "output", "text": "green\n" }));
    assert_eq!(events[1], json!({ "event": "output", "text": "second\n" }));
    // Every output tap sees the whole stream before any close tap fires — the ordering contract
    // `slopdesk_hostsession::taps` states and this is the wire-level reading of it.
    assert_eq!(events[2], json!({ "event": "closed" }));
}

#[test]
fn a_subscriber_that_asks_for_the_escapes_gets_them() {
    let pane = Ghost::numbered(7);
    let wire = Wire::to(Host::holding(&pane));
    wire.send(
        b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"p1\",\"ansiStrip\":false}}\n",
    );
    while pane.output_taps() == 0 {
        std::thread::yield_now();
    }
    pane.emit(b"\x1b[32mgreen\x1b[0m\n");
    let events = wire.lines(1);
    assert_eq!(events[0]["text"], json!("\u{1b}[32mgreen\u{1b}[0m\n"));
}

#[test]
fn a_subscribe_that_races_its_panes_exit_is_answered_rather_than_parked_forever() {
    let pane = Ghost::numbered(7);
    // The pane is still ADOPTED — it ended, and nothing has swept it from the registry yet, which
    // is the whole window this race lives in. A `subscribe` arriving now finds it, so the refusal
    // above cannot save the caller.
    pane.end();
    let wire = Wire::to(Host::holding(&pane));
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"p1\"}}\n");

    // `add_close_tap` fires a LATE registration at once rather than dropping it — the latch the
    // Swift lacked, where this waited out its own timeout for an event that had already happened.
    let events = wire.lines(1);
    assert_eq!(events[0], json!({ "event": "closed" }));
}

#[test]
fn a_subscribe_naming_a_pane_that_is_not_there_is_refused_rather_than_parked() {
    let wire = Wire::to(Host::empty());
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"ghost\"}}\n");
    let answers = wire.lines(1);
    assert_eq!(answers[0]["error"], json!("pane not found: ghost"));
}

#[test]
fn a_pane_id_of_the_wrong_type_is_refused_rather_than_read_as_the_all_mode() {
    let wire = Wire::to(Host::empty());
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":7}}\n");
    let answers = wire.lines(1);
    // A DEPARTURE from the Swift, which fell through to the cross-pane stream. The caller meant one
    // pane and named it wrongly; answering with every pane's status is a silent substitution.
    assert_eq!(answers[0]["error"], json!("params.paneId must be a string"));
}

#[test]
fn subscribe_with_no_pane_id_is_the_cross_pane_stream_deduped_on_state_and_presence() {
    let host = Host::empty();
    let wire = Wire::to(Arc::clone(&host));
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\"}\n");

    while host.status_taps.count() == 0 {
        std::thread::yield_now();
    }
    let moved = |state: &str, present: bool, ts: i64| {
        host.move_pane(&AgentStatusEvent {
            pane_id: String::from("p1"),
            state: state.to_owned(),
            agent_present: present,
            title: String::from("work"),
            ts,
        });
    };
    moved("working", true, 1);
    moved("working", true, 2); // the same key — swallowed
    moved("idle", true, 3);
    // The agent-GONE edge lands on the same `"idle"` string, so a state-only dedupe key would
    // swallow the one transition a supervisor most needs to see.
    moved("idle", false, 4);

    let events = wire.lines(3);
    assert_eq!(events[0]["state"], json!("working"));
    assert_eq!(events[0]["type"], json!("agent_status_changed"));
    assert_eq!(events[0]["ts"], json!(1));
    assert_eq!(events[1]["state"], json!("idle"));
    assert_eq!(events[1]["agentPresent"], json!(true));
    assert_eq!(
        events[2]["agentPresent"],
        json!(false),
        "the GONE edge is its own event"
    );
    assert_eq!(events[2]["title"], json!("work"));
}

#[test]
fn a_subscriber_that_hangs_up_retires_its_taps() {
    let pane = Ghost::numbered(7);
    let wire = Wire::to(Host::holding(&pane));
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"p1\"}}\n");
    while pane.output_taps() == 0 {
        std::thread::yield_now();
    }

    // Without the connection in the pump's `poll` set, an abandoned subscription would keep its
    // taps, its thread and its descriptors for as long as the host ran — which the never-DoS
    // posture forbids.
    wire.hang_up();
    while pane.output_taps() > 0 || pane.close_taps() > 0 {
        std::thread::yield_now();
    }
}

#[test]
fn a_subscriber_that_talks_is_read_and_ignored_rather_than_hung_up_on() {
    let pane = Ghost::numbered(7);
    let wire = Wire::to(Host::holding(&pane));
    wire.send(b"{\"id\":\"s\",\"method\":\"subscribe\",\"params\":{\"paneId\":\"p1\"}}\n");
    while pane.output_taps() == 0 {
        std::thread::yield_now();
    }
    // The protocol has nothing for a subscriber to say, but hanging up on one for saying it would
    // be a stricter contract than the Swift's.
    wire.send(b"{\"id\":\"x\",\"method\":\"list-panes\"}\n");
    pane.emit(b"still here\n");
    let events = wire.lines(1);
    assert_eq!(events[0], json!({ "event": "output", "text": "still here\n" }));
}
