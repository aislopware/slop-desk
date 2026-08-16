//! The NDJSON request/response shapes of the agent-control socket, and one builder per verb.
//!
//! Every builder is pure and returns a `serde_json::Map`, so a test can assert on the exact
//! parameter object a subcommand would put on the wire without opening a socket.
//!
//! ## Number shapes are load-bearing
//! The server reads `rows`/`cols`/`n`/`lines` with `params["rows"] as? Int` and `timeoutMs` with
//! `as? Double` (`AgentControlListener.swift`). A Foundation `NSNumber` bridged from a JSON
//! *integer* satisfies both casts; one bridged from a *float* satisfies only the `Double` one. So
//! the size-like fields must serialise as integers, which `i64` does, and [`millis`] renders a
//! whole-numbered timeout as an integer too — reproducing what `JSONSerialization` wrote for a
//! Swift `Double` of 30000 and keeping the request byte-compatible with the server that is still
//! Swift.

use serde_json::{Map, Value};

/// A JSON object, in the one spelling this crate uses.
pub type Params = Map<String, Value>;

/// Renders a millisecond duration the way `JSONSerialization` rendered the Swift `Double`: as a
/// JSON integer when it is whole, and only otherwise as a float.
#[must_use]
pub fn millis(value: f64) -> Value {
    // The guard is the cast's proof: only a finite, whole value inside `i64`'s range takes the
    // integer arm, so nothing is truncated and nothing saturates.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "guarded: fract() == 0 and the value is inside i64's range"
    )]
    if value.is_finite() && value.fract() == 0.0 && value.abs() < 9.007_199_254_740_992e15 {
        Value::from(value as i64)
    } else {
        Value::from(value)
    }
}

/// Encodes one request into an NDJSON line, WITHOUT the trailing LF — the caller appends it.
///
/// Keys come out sorted, because `serde_json`'s object is a `BTreeMap`; that is the same ordering
/// Foundation's `.sortedKeys` produced, which is what keeps the line stable and greppable.
#[must_use]
pub fn encode_request_line(id: &str, method: &str, params: Params) -> String {
    let mut root = Map::new();
    root.insert("id".to_owned(), Value::from(id));
    root.insert("method".to_owned(), Value::from(method));
    root.insert("params".to_owned(), Value::Object(params));
    Value::Object(root).to_string()
}

/// Parses one NDJSON response line into an object, or `None` when it is not a JSON object.
///
/// Validate-then-drop: a malformed line, a non-UTF-8 line and a bare JSON scalar all read as
/// `None`, so a caller cannot mistake a fragment of a broken response for a real answer.
#[must_use]
pub fn decode_response_line(line: &str) -> Option<Params> {
    match serde_json::from_str::<Value>(line) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// Re-encodes a whole response object for `--json` output, sorted.
///
/// ## The one output byte the port deliberately changes
/// `JSONSerialization` escaped a forward slash as `\/`, so the Swift printed
/// `"cwd":"\/Users\/x"`. That escape is a legacy JavaScript-embedding habit, not a JSON
/// requirement; `serde_json` emits `"cwd":"/Users/x"`. Every parser reads the two identically —
/// `jq`, `python -m json.tool`, `JSONSerialization` itself — so the only reader that can tell is a
/// naive `grep` for a literal path, and that reader is served BETTER by the unescaped form. Pinned
/// below rather than left to be discovered.
#[must_use]
pub fn encode_response_line(obj: &Params) -> String {
    Value::Object(obj.clone()).to_string()
}

// ---------------------------------------------------------------------------------------------
// Verb parameter builders
// ---------------------------------------------------------------------------------------------

/// `list-panes` takes nothing.
#[must_use]
pub fn list_panes_params() -> Params {
    Params::new()
}

/// `read` — the pane's scrollback.
///
/// `unwrapped` asks for the logical-line view (`source: "unwrapped"`): the host joins chunks,
/// strips ANSI, splits on hard newlines and drops the partial trailing line, so an agent's regex
/// is robust to read-chunk boundaries. `lines` is a last-N cap and is only meaningful there.
#[must_use]
pub fn read_params(pane_id: &str, ansi_strip: bool, unwrapped: bool, lines: Option<i64>) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("ansiStrip".to_owned(), Value::from(ansi_strip));
    if unwrapped {
        params.insert("source".to_owned(), Value::from("unwrapped"));
        if let Some(n) = lines.filter(|n| *n > 0) {
            params.insert("lines".to_owned(), Value::from(n));
        }
    }
    params
}

/// `screen` — the RENDERED grid. `rows`/`cols` of `None` mean the live PTY winsize.
#[must_use]
pub fn screen_params(pane_id: &str, rows: Option<i64>, cols: Option<i64>) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    if let Some(r) = rows {
        params.insert("rows".to_owned(), Value::from(r));
    }
    if let Some(c) = cols {
        params.insert("cols".to_owned(), Value::from(c));
    }
    params
}

/// `write` — raw text and/or named keys, text first. At least one must be present; the caller
/// enforces that, because "neither" is a usage error with its own message.
#[must_use]
pub fn write_params(pane_id: &str, text: Option<&str>, keys: &[String]) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    if let Some(t) = text {
        params.insert("text".to_owned(), Value::from(t));
    }
    if !keys.is_empty() {
        params.insert("keys".to_owned(), Value::from(keys));
    }
    params
}

/// `run` — text plus an implicit Enter, sent as one atomic write. With `wait` the host blocks
/// until the command's OSC-133 block closes and answers `{matched, exitCode?, durationMs?,
/// output}`.
#[must_use]
pub fn run_params(pane_id: &str, cmd: &str, wait: bool, timeout_ms: f64, ansi_strip: bool) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("text".to_owned(), Value::from(cmd));
    if wait {
        params.insert("wait".to_owned(), Value::from(true));
        params.insert("timeoutMs".to_owned(), millis(timeout_ms));
        params.insert("ansiStrip".to_owned(), Value::from(ansi_strip));
    }
    params
}

/// `wait`, output-regex arm.
#[must_use]
pub fn wait_params(pane_id: &str, until: &str, timeout_ms: f64) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("until".to_owned(), Value::from(until));
    params.insert("timeoutMs".to_owned(), millis(timeout_ms));
    params
}

/// `wait`, agent-state arm: block until the pane's supervision state is in `states`, a comma-set
/// of `idle`/`working`/`done`/`blocked`.
#[must_use]
pub fn wait_state_params(pane_id: &str, states: &str, timeout_ms: f64) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("state".to_owned(), Value::from(states));
    params.insert("timeoutMs".to_owned(), millis(timeout_ms));
    params
}

/// `last-output` — the last `n` closed OSC-133 blocks, newest last.
#[must_use]
pub fn last_output_params(pane_id: &str, n: i64, ansi_strip: bool) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("n".to_owned(), Value::from(n));
    params.insert("ansiStrip".to_owned(), Value::from(ansi_strip));
    params
}

/// `spawn` — a new standalone PTY pane. `cmd` is passed as `<shell> -c <cmd>`; without it the host
/// spawns the login shell.
#[must_use]
pub fn spawn_params(
    cmd: Option<&str>,
    cwd: Option<&str>,
    env: &[(String, String)],
    rows: i64,
    cols: i64,
    shell_path: &str,
) -> Params {
    let mut params = Params::new();
    params.insert("rows".to_owned(), Value::from(rows));
    params.insert("cols".to_owned(), Value::from(cols));
    if let Some(c) = cmd {
        params.insert(
            "cmd".to_owned(),
            Value::from(vec![Value::from(shell_path), Value::from("-c"), Value::from(c)]),
        );
    }
    if let Some(dir) = cwd {
        params.insert("cwd".to_owned(), Value::from(dir));
    }
    if !env.is_empty() {
        let mut map = Map::new();
        for (key, value) in env {
            map.insert(key.clone(), Value::from(value.as_str()));
        }
        params.insert("env".to_owned(), Value::Object(map));
    }
    params
}

/// `kill` — end a pane by id.
#[must_use]
pub fn kill_params(pane_id: &str) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params
}

/// `subscribe`, per-pane arm: stream this pane's live output.
#[must_use]
pub fn subscribe_params(pane_id: &str, ansi_strip: bool) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("ansiStrip".to_owned(), Value::from(ansi_strip));
    params
}

/// `subscribe`, top-level arm — the `events` stream. The ABSENCE of `paneId` is the whole
/// contract: the host reads an empty object as "fan `agent_status_changed` across all panes".
#[must_use]
pub fn subscribe_all_params() -> Params {
    Params::new()
}

/// `report` — the agent self-declares its supervision state, which outranks the host's heuristic.
#[must_use]
pub fn report_params(pane_id: &str, state: &str, message: Option<&str>) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("state".to_owned(), Value::from(state));
    if let Some(text) = message {
        params.insert("message".to_owned(), Value::from(text));
    }
    params
}

/// `resize` — set the pane's PTY winsize.
#[must_use]
pub fn resize_params(pane_id: &str, rows: i64, cols: i64) -> Params {
    let mut params = Params::new();
    params.insert("paneId".to_owned(), Value::from(pane_id));
    params.insert("rows".to_owned(), Value::from(rows));
    params.insert("cols".to_owned(), Value::from(cols));
    params
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::Value;

    use super::{
        decode_response_line, encode_request_line, encode_response_line, kill_params, last_output_params,
        millis, read_params, report_params, resize_params, run_params, screen_params, spawn_params,
        subscribe_all_params, subscribe_params, wait_params, wait_state_params, write_params,
    };

    fn reparse(line: &str) -> Value {
        serde_json::from_str(line).expect("the encoder emits valid JSON")
    }

    // MARK: number shapes

    #[test]
    fn a_whole_timeout_serialises_as_an_integer_so_the_swift_int_cast_still_succeeds() {
        assert_eq!(millis(30000.0).to_string(), "30000");
        assert_eq!(millis(0.0).to_string(), "0");
    }

    #[test]
    fn a_fractional_timeout_keeps_its_fraction() {
        assert_eq!(millis(1500.5).to_string(), "1500.5");
    }

    #[test]
    fn a_non_finite_timeout_does_not_take_the_integer_arm() {
        // `f64::NAN as i64` is 0, which would silently turn "no timeout I can express" into "expire
        // immediately". The finite guard is what stops that; JSON has no NaN, so serde renders null
        // and the server falls back to its own 30 s default.
        assert_eq!(millis(f64::NAN).to_string(), "null");
        assert_eq!(millis(f64::INFINITY).to_string(), "null");
    }

    // MARK: request framing

    #[test]
    fn a_request_line_carries_id_method_and_params_and_no_trailing_newline() {
        let line = encode_request_line("42", "list-panes", super::list_panes_params());
        assert!(
            !line.ends_with('\n'),
            "the caller appends the LF, not the encoder"
        );
        let obj = reparse(&line);
        assert_eq!(obj["id"], Value::from("42"));
        assert_eq!(obj["method"], Value::from("list-panes"));
        assert!(obj["params"].is_object());
    }

    #[test]
    fn request_keys_come_out_sorted_the_way_foundations_sortedkeys_wrote_them() {
        let line = encode_request_line("1", "read", read_params("abc", true, false, None));
        assert_eq!(
            line,
            r#"{"id":"1","method":"read","params":{"ansiStrip":true,"paneId":"abc"}}"#
        );
    }

    // MARK: response decoding

    #[test]
    fn a_success_response_decodes_to_its_object() {
        let obj = decode_response_line(r#"{"id":"1","ok":true,"result":{"text":"hello"}}"#)
            .expect("a well-formed object decodes");
        assert_eq!(obj["ok"], Value::from(true));
        assert_eq!(obj["result"]["text"], Value::from("hello"));
    }

    #[test]
    fn an_error_response_decodes_with_its_message() {
        let obj = decode_response_line(r#"{"id":"1","ok":false,"error":"pane not found"}"#)
            .expect("a well-formed object decodes");
        assert_eq!(obj["ok"], Value::from(false));
        assert_eq!(obj["error"], Value::from("pane not found"));
    }

    #[test]
    fn malformed_empty_and_non_object_lines_all_read_as_nothing() {
        assert!(decode_response_line("{not valid json").is_none());
        assert!(decode_response_line("").is_none());
        // A bare scalar is valid JSON but is not a response, and must not be mistaken for one.
        assert!(decode_response_line("42").is_none());
        assert!(decode_response_line("[1,2]").is_none());
    }

    #[test]
    fn a_path_in_json_output_keeps_its_slashes_unescaped() {
        // The deliberate difference from `JSONSerialization`, which wrote `\/`. Asserted so a
        // future change to it is a decision rather than a surprise.
        let obj = decode_response_line(r#"{"cwd":"/Users/x/code"}"#).expect("decodes");
        assert_eq!(encode_response_line(&obj), r#"{"cwd":"/Users/x/code"}"#);
    }

    #[test]
    fn re_encoding_a_response_sorts_its_keys() {
        let obj = decode_response_line(r#"{"z":1,"a":2,"m":{"y":1,"b":2}}"#).expect("decodes");
        assert_eq!(encode_response_line(&obj), r#"{"a":2,"m":{"b":2,"y":1},"z":1}"#);
    }

    // MARK: verb builders

    #[test]
    fn run_without_wait_sends_only_the_pane_and_the_text() {
        let params = run_params("foo-uuid", "ls", false, 30000.0, true);
        assert_eq!(params["paneId"], Value::from("foo-uuid"));
        assert_eq!(params["text"], Value::from("ls"));
        assert!(params.get("wait").is_none());
        assert!(params.get("timeoutMs").is_none());
        assert!(params.get("ansiStrip").is_none());
    }

    #[test]
    fn run_with_wait_carries_the_timeout_and_the_strip_flag() {
        let params = run_params("p", "ls", true, 5000.0, false);
        assert_eq!(params["wait"], Value::from(true));
        assert_eq!(params["timeoutMs"].to_string(), "5000");
        assert_eq!(params["ansiStrip"], Value::from(false));
    }

    #[test]
    fn wait_defaults_to_thirty_seconds_and_honours_an_override() {
        assert_eq!(
            wait_params("p1", "\\$", 30000.0)["timeoutMs"].to_string(),
            "30000"
        );
        assert_eq!(wait_params("p1", "DONE", 5000.0)["timeoutMs"].to_string(), "5000");
    }

    #[test]
    fn the_state_arm_of_wait_sends_state_and_never_until() {
        let params = wait_state_params("p1", "done,blocked", 30000.0);
        assert_eq!(params["state"], Value::from("done,blocked"));
        assert!(params.get("until").is_none());
    }

    #[test]
    fn spawn_without_a_command_omits_cmd_so_the_host_starts_the_login_shell() {
        let params = spawn_params(None, None, &[], 24, 80, "/bin/zsh");
        assert!(params.get("cmd").is_none());
        assert_eq!(params["rows"].to_string(), "24");
        assert_eq!(params["cols"].to_string(), "80");
    }

    #[test]
    fn spawn_with_a_command_wraps_it_in_the_shells_dash_c() {
        let env = vec![("FOO".to_owned(), "bar".to_owned())];
        let params = spawn_params(Some("ls -la"), Some("/tmp"), &env, 30, 120, "/bin/zsh");
        assert_eq!(params["cmd"].to_string(), r#"["/bin/zsh","-c","ls -la"]"#);
        assert_eq!(params["cwd"], Value::from("/tmp"));
        assert_eq!(params["env"]["FOO"], Value::from("bar"));
        assert_eq!(params["rows"].to_string(), "30");
        assert_eq!(params["cols"].to_string(), "120");
    }

    #[test]
    fn a_plain_read_asks_for_no_source_and_an_unwrapped_read_does() {
        assert!(read_params("p", true, false, None).get("source").is_none());
        let unwrapped = read_params("p", true, true, None);
        assert_eq!(unwrapped["source"], Value::from("unwrapped"));
        assert!(unwrapped.get("lines").is_none());
    }

    #[test]
    fn a_line_cap_rides_only_the_unwrapped_read_because_only_the_host_applies_it_there() {
        assert_eq!(read_params("p", true, true, Some(20))["lines"].to_string(), "20");
        assert!(read_params("p", true, false, Some(20)).get("lines").is_none());
        // A non-positive cap is not a cap.
        assert!(read_params("p", true, true, Some(0)).get("lines").is_none());
    }

    #[test]
    fn read_carries_the_inverted_ansi_flag_both_ways() {
        assert_eq!(
            read_params("p", true, false, None)["ansiStrip"],
            Value::from(true)
        );
        assert_eq!(
            read_params("p", false, false, None)["ansiStrip"],
            Value::from(false)
        );
    }

    #[test]
    fn write_can_send_text_alone_keys_alone_or_both() {
        let text_only = write_params("p", Some("ls"), &[]);
        assert_eq!(text_only["text"], Value::from("ls"));
        assert!(text_only.get("keys").is_none());

        let keys_only = write_params("p", None, &["Enter".to_owned()]);
        assert!(keys_only.get("text").is_none());
        assert_eq!(keys_only["keys"].to_string(), r#"["Enter"]"#);

        let both = write_params("p", Some("ls"), &["Enter".to_owned()]);
        assert_eq!(both["text"], Value::from("ls"));
        assert_eq!(both["keys"].to_string(), r#"["Enter"]"#);
    }

    #[test]
    fn screen_defaults_to_the_live_size_and_takes_an_override() {
        let live = screen_params("p", None, None);
        assert!(live.get("rows").is_none() && live.get("cols").is_none());
        let sized = screen_params("p", Some(40), Some(100));
        assert_eq!(sized["rows"].to_string(), "40");
        assert_eq!(sized["cols"].to_string(), "100");
    }

    #[test]
    fn last_output_defaults_to_one_block_and_stripped_output() {
        let params = last_output_params("p", 1, true);
        assert_eq!(params["n"].to_string(), "1");
        assert_eq!(params["ansiStrip"], Value::from(true));
        assert_eq!(last_output_params("p", 5, false)["n"].to_string(), "5");
    }

    #[test]
    fn report_omits_the_message_when_there_is_none() {
        assert!(report_params("p", "done", None).get("message").is_none());
        assert_eq!(
            report_params("p", "blocked", Some("which one?"))["message"],
            Value::from("which one?")
        );
    }

    #[test]
    fn the_top_level_subscribe_sends_an_empty_object_and_the_per_pane_one_does_not() {
        assert!(subscribe_all_params().is_empty());
        let per_pane = subscribe_params("p", true);
        assert_eq!(per_pane["paneId"], Value::from("p"));
        assert_eq!(per_pane["ansiStrip"], Value::from(true));
        assert_eq!(subscribe_params("p", false)["ansiStrip"], Value::from(false));
    }

    #[test]
    fn kill_and_resize_carry_exactly_their_arguments() {
        assert_eq!(kill_params("p").len(), 1);
        let resize = resize_params("p", 40, 100);
        assert_eq!(resize["rows"].to_string(), "40");
        assert_eq!(resize["cols"].to_string(), "100");
    }

    #[test]
    fn a_hostile_pane_title_round_trips_through_the_encoder_unharmed() {
        // The strings in these params come from a foreign program's PTY output. Quote, backslash,
        // newline, NUL and a lone-surrogate-free astral char all have to survive re-encoding.
        let nasty = "a\"b\\c\nd\te\u{0}f\u{1F600}";
        let line = encode_request_line("1", "write", write_params("p", Some(nasty), &[]));
        let obj = reparse(&line);
        assert_eq!(obj["params"]["text"], Value::from(nasty));
    }
}
