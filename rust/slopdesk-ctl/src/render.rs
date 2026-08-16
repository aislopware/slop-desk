//! Everything the CLI prints, as pure `String`-returning functions.
//!
//! In the Swift original this formatting lived inside `main.swift` next to the socket calls, so
//! none of it was reachable from a test — the `list-panes` table, the block rendering and the
//! `run --wait` status line were compiled-and-reviewed only. Splitting them out is the one place
//! this port deliberately changes shape rather than transliterating: the strings being formatted
//! come from a foreign program's PTY output, and that is worth pinning.

use std::fmt::Write as _;

use serde_json::{Map, Value};

/// A JSON object, in the one spelling this crate uses.
type Obj = Map<String, Value>;

/// Reads an integer field that the host may have written as a JSON integer or as a whole float.
///
/// Foundation's `as? Int` accepted both, because an `NSNumber` bridges on exact value rather than
/// on how the number was spelled. `as_i64` alone would reject `3.0` and silently show `-` where the
/// Swift showed `3`.
fn int_field(obj: &Obj, key: &str) -> Option<i64> {
    let value = obj.get(key)?;
    #[expect(
        clippy::cast_possible_truncation,
        reason = "guarded: fract() == 0 and the value is inside i64's range"
    )]
    match value {
        Value::Number(n) => {
            n.as_i64().or_else(|| {
                n.as_f64()
                    .filter(|f| f.is_finite() && f.fract() == 0.0 && f.abs() < 9.007_199_254_740_992e15)
                    .map(|f| f as i64)
            })
        },
        _ => None,
    }
}

fn str_field<'a>(obj: &'a Obj, key: &str) -> Option<&'a str> {
    obj.get(key).and_then(Value::as_str)
}

/// Left-pads `text` to `width`.
///
/// Width is counted in `char`s. The Swift counted grapheme clusters and neither is the terminal's
/// own answer (that is display width, where one CJK glyph is two columns), so the two disagree only
/// on combining sequences in a `CMD` or `CWD` field — a cosmetic column wobble in a human-readable
/// table, which is not worth a Unicode-segmentation dependency in a binary whose cost is startup.
fn pad(text: &str, width: usize) -> String {
    let len = text.chars().count();
    if len >= width {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len() + (width - len));
    out.push_str(text);
    out.extend(std::iter::repeat_n(' ', width - len));
    out
}

/// Shortens a leading `$HOME` to `~`, the way a shell prompt does. `home` empty means no
/// shortening.
#[must_use]
pub fn home_shorten(path: &str, home: &str) -> String {
    if !home.is_empty() && path.starts_with(home) {
        let mut out = String::from("~");
        out.push_str(path.get(home.len()..).unwrap_or_default());
        return out;
    }
    path.to_owned()
}

/// The `list-panes` table, header included. `home` shortens each pane's cwd.
///
/// An empty pane list renders as the `(no live panes)` note rather than a bare header.
#[must_use]
pub fn list_panes_table(panes: &[Value], home: &str) -> String {
    if panes.is_empty() {
        return "(no live panes)\n".to_owned();
    }
    let mut out = format!(
        "{}  {}  {}  {}  {}  {}  {}  TITLE\n",
        pad("PANE-ID", 36),
        pad("PID", 6),
        pad("STATUS", 6),
        pad("AGENT", 8),
        pad("EXIT", 4),
        pad("CMD", 10),
        pad("CWD", 28),
    );
    for pane in panes {
        let Some(pane) = pane.as_object() else { continue };
        let pane_id = str_field(pane, "paneId").unwrap_or("-");
        let pid = int_field(pane, "pid").unwrap_or(-1);
        let title = str_field(pane, "title").unwrap_or("");
        let status = if pane.get("isAlive").and_then(Value::as_bool) == Some(true) {
            "alive"
        } else {
            "dead"
        };
        // The P1 supervision state. A host older than that verb omits it entirely → `-`.
        let agent = str_field(pane, "state").unwrap_or("-");
        let exit = int_field(pane, "lastExitCode").map_or_else(|| "-".to_owned(), |c| c.to_string());
        let command = match str_field(pane, "command") {
            Some(c) if !c.is_empty() => c,
            _ => "-",
        };
        let cwd = str_field(pane, "cwd").map_or_else(|| "-".to_owned(), |raw| home_shorten(raw, home));

        // `write!` into a String cannot fail (`fmt::Error` is reserved for a formatter that can),
        // so the result is discarded rather than unwrapped — the renderer stays panic-free.
        let _ = writeln!(
            out,
            "{}  {}  {}  {}  {}  {}  {}  {title}",
            pad(pane_id, 36),
            pad(&pid.to_string(), 6),
            pad(status, 6),
            pad(agent, 8),
            pad(&exit, 4),
            pad(command, 10),
            pad(&cwd, 28),
        );
        // A blocked pane's question rides `list-panes` directly, so an orchestrator never has to
        // scrape scrollback to find out what it is being asked.
        if let Some(message) = str_field(pane, "stateMessage").filter(|m| !m.is_empty()) {
            let _ = writeln!(out, "{}  └ {message}", pad("", 36));
        }
    }
    out
}

/// The `last-output` rendering: one heading per closed OSC-133 block, its output verbatim, and a
/// trailing note for a command that is still running.
#[must_use]
pub fn last_output_report(result: &Obj) -> String {
    let mut out = String::new();
    let blocks = result.get("blocks").and_then(Value::as_array);
    match blocks {
        Some(list) if !list.is_empty() => {
            for block in list {
                let Some(block) = block.as_object() else { continue };
                let command = str_field(block, "command").unwrap_or("");
                let exit = int_field(block, "exitCode")
                    .map_or_else(|| "no exit code".to_owned(), |c| format!("exit {c}"));
                let duration =
                    int_field(block, "durationMs").map_or_else(String::new, |ms| format!(", {ms}ms"));
                // Absent `complete` means complete: the field was added after the verb, and an
                // older host's finished block is not an interrupted one.
                let complete = block.get("complete").and_then(Value::as_bool).unwrap_or(true);
                let marker = if complete { "" } else { " [interrupted]" };
                let _ = writeln!(out, "$ {command}  ({exit}{duration}){marker}");
                let output = str_field(block, "output").unwrap_or("");
                out.push_str(output);
                if !output.ends_with('\n') {
                    out.push('\n');
                }
            }
        },
        _ => out.push_str("(no finished commands)\n"),
    }
    if let Some(running) = result.get("running").and_then(Value::as_object) {
        let command = str_field(running, "command").unwrap_or("");
        let output_len = int_field(running, "outputLen").unwrap_or(0);
        let _ = writeln!(out, "… running: $ {command}  ({output_len} output bytes so far)");
    }
    out
}

/// Appends a newline unless `text` already ends in one.
///
/// The "print this blob readably" rule the `read`, `screen` and `run --wait` paths all share. An
/// EMPTY body stays empty for `run`, which is why the caller decides whether to route through here.
#[must_use]
pub fn newline_terminated(text: &str) -> String {
    if text.ends_with('\n') {
        return text.to_owned();
    }
    let mut out = text.to_owned();
    out.push('\n');
    out
}

/// Truncates a millisecond count toward zero for a message.
///
/// Swift wrote `Int(elapsed)`, which TRAPS on a NaN or infinite `Double` — a malformed `elapsed`
/// from the host would have crashed the CLI instead of reporting a timeout. This saturates instead,
/// which is the only behavioural difference and is strictly the safer one.
#[must_use]
pub const fn truncate_ms(value: f64) -> i64 {
    if value.is_nan() {
        return 0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "an `as` cast from f64 to i64 saturates at the bounds, which is the intent here"
    )]
    {
        value.trunc() as i64
    }
}

/// The last N lines of `text`, joined back with `\n`.
///
/// Only the non-`--unwrapped` `read` path uses this: there the host returns the whole snapshot and
/// the cap is applied here, whereas `--unwrapped` asks the host to apply it and returns text that
/// is already trimmed.
#[must_use]
pub fn last_lines(text: &str, limit: usize) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let start = lines.len().saturating_sub(limit);
    lines.get(start..).unwrap_or_default().join("\n")
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::{Map, Value, json};

    use super::{
        home_shorten, last_lines, last_output_report, list_panes_table, newline_terminated, truncate_ms,
    };

    fn obj(value: &Value) -> Map<String, Value> {
        value.as_object().expect("a test literal object").clone()
    }

    #[test]
    fn an_empty_pane_list_says_so_instead_of_printing_a_bare_header() {
        assert_eq!(list_panes_table(&[], "/Users/x"), "(no live panes)\n");
    }

    #[test]
    fn a_pane_row_lines_up_under_the_header_and_shortens_its_cwd() {
        let panes = vec![json!({
            "paneId": "11111111-2222-3333-4444-555555555555",
            "pid": 4242,
            "isAlive": true,
            "state": "working",
            "lastExitCode": 0,
            "command": "zsh",
            "cwd": "/Users/x/code",
            "title": "a title",
        })];
        let table = list_panes_table(&panes, "/Users/x");
        let mut lines = table.lines();
        let header = lines.next().expect("a header");
        let row = lines.next().expect("a row");
        assert!(header.starts_with("PANE-ID"));
        assert!(header.ends_with("TITLE"));
        assert!(row.contains("11111111-2222-3333-4444-555555555555"));
        assert!(row.contains("alive"));
        assert!(row.contains("working"));
        assert!(row.contains("~/code"), "the cwd is home-shortened: {row}");
        assert!(row.ends_with("a title"));
        // The columns are fixed-width, so the header's TITLE and the row's title start together.
        let title_column = header.find("TITLE").expect("the header names TITLE");
        assert_eq!(row.find("a title"), Some(title_column));
    }

    #[test]
    fn a_pane_missing_every_optional_field_renders_dashes_rather_than_blanks() {
        let panes = vec![json!({})];
        let row = list_panes_table(&panes, "")
            .lines()
            .nth(1)
            .expect("a row")
            .to_owned();
        assert!(row.starts_with("-  "), "a missing paneId is a dash: {row}");
        assert!(row.contains("-1"), "a missing pid is -1: {row}");
        assert!(row.contains("dead"), "a pane with no isAlive is dead: {row}");
    }

    #[test]
    fn a_blocked_panes_question_gets_its_own_indented_line() {
        let panes = vec![json!({ "paneId": "p", "stateMessage": "which file?" })];
        let table = list_panes_table(&panes, "");
        assert!(table.contains("└ which file?"), "{table}");
        // An empty message is not a question, and must not print an empty branch.
        let quiet = vec![json!({ "paneId": "p", "stateMessage": "" })];
        assert!(!list_panes_table(&quiet, "").contains('└'));
    }

    #[test]
    fn home_shortening_only_fires_on_a_real_prefix_and_never_on_an_empty_home() {
        assert_eq!(home_shorten("/Users/x/code", "/Users/x"), "~/code");
        assert_eq!(home_shorten("/Users/x", "/Users/x"), "~");
        assert_eq!(home_shorten("/tmp/x", "/Users/x"), "/tmp/x");
        assert_eq!(home_shorten("/Users/x/code", ""), "/Users/x/code");
    }

    #[test]
    fn no_blocks_reads_as_no_finished_commands() {
        assert_eq!(last_output_report(&obj(&json!({}))), "(no finished commands)\n");
        assert_eq!(
            last_output_report(&obj(&json!({ "blocks": [] }))),
            "(no finished commands)\n"
        );
    }

    #[test]
    fn a_finished_block_prints_its_command_exit_and_duration_then_its_output() {
        let result = obj(&json!({
            "blocks": [{ "command": "ls", "exitCode": 0, "durationMs": 12, "output": "a\nb\n" }],
        }));
        assert_eq!(last_output_report(&result), "$ ls  (exit 0, 12ms)\na\nb\n");
    }

    #[test]
    fn a_block_whose_output_lacks_a_newline_gets_one_so_the_next_heading_starts_a_line() {
        let result = obj(&json!({ "blocks": [{ "command": "echo -n hi", "output": "hi" }] }));
        assert_eq!(last_output_report(&result), "$ echo -n hi  (no exit code)\nhi\n");
    }

    #[test]
    fn an_incomplete_block_is_marked_and_a_field_less_one_is_not() {
        let cut = obj(&json!({ "blocks": [{ "command": "sleep 9", "complete": false }] }));
        assert!(last_output_report(&cut).contains("[interrupted]"));
        let old_host = obj(&json!({ "blocks": [{ "command": "sleep 9" }] }));
        assert!(!last_output_report(&old_host).contains("[interrupted]"));
    }

    #[test]
    fn a_still_running_command_is_noted_after_the_finished_ones() {
        let result = obj(&json!({
            "blocks": [{ "command": "ls", "exitCode": 0, "output": "a\n" }],
            "running": { "command": "tail -f log", "outputLen": 4096 },
        }));
        let report = last_output_report(&result);
        assert!(
            report.ends_with("… running: $ tail -f log  (4096 output bytes so far)\n"),
            "{report}"
        );
    }

    #[test]
    fn a_whole_float_from_the_host_still_reads_as_an_integer_field() {
        // Foundation's `as? Int` accepted an NSNumber holding 4242.0; rejecting it here would show
        // a dash where the Swift showed the pid.
        let panes = vec![json!({ "paneId": "p", "pid": 4242.0 })];
        assert!(list_panes_table(&panes, "").contains("4242"));
    }

    #[test]
    fn a_newline_is_added_only_when_one_is_missing() {
        assert_eq!(newline_terminated("a"), "a\n");
        assert_eq!(newline_terminated("a\n"), "a\n");
        assert_eq!(newline_terminated(""), "\n");
    }

    #[test]
    fn a_millisecond_count_truncates_toward_zero_and_survives_a_malformed_one() {
        assert_eq!(truncate_ms(1999.9), 1999);
        assert_eq!(truncate_ms(0.0), 0);
        // Swift's `Int(Double)` TRAPPED on these; the CLI now reports rather than crashes.
        assert_eq!(truncate_ms(f64::NAN), 0);
        assert_eq!(truncate_ms(f64::INFINITY), i64::MAX);
    }

    #[test]
    fn the_last_n_lines_keep_their_separators_and_a_short_text_is_untouched() {
        assert_eq!(last_lines("a\nb\nc\nd", 2), "c\nd");
        assert_eq!(last_lines("a\nb", 10), "a\nb");
        assert_eq!(last_lines("", 3), "");
        // A trailing newline is a final EMPTY line, exactly as `components(separatedBy:)` saw it.
        assert_eq!(last_lines("a\nb\n", 2), "b\n");
    }
}
