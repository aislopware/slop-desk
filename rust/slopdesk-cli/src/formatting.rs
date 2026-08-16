//! Everything the list and inspect subcommands print.
//!
//! Each formatter is a deterministic transform over rows decoded from the control socket's NDJSON —
//! no socket, no I/O — so the whole table and JSON surface is testable without a running app.
//!
//! Validate-then-drop on the rows: a missing or wrong-typed field renders as an EMPTY CELL rather
//! than trapping. These rows describe panes whose titles and cwds a foreign program drew into a
//! PTY, so a surprising shape is a Tuesday, not an exception.

use serde_json::{Map, Value};

use crate::args::OutputFormat;

/// A JSON object row, in the one spelling this module uses.
pub type Row = Map<String, Value>;

/// `windows` — `ID · TITLE · TABS · FOCUSED`.
#[must_use]
pub fn windows(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(
        rows,
        format,
        no_headers,
        &["ID", "TITLE", "TABS", "FOCUSED"],
        &|row| {
            vec![
                string(row, "id"),
                string(row, "title"),
                integer(row, "tabCount"),
                marker(row, "focused"),
            ]
        },
    )
}

/// `tabs` — `ID · WINDOW · TITLE · PANES · FOCUSED · BADGE`.
#[must_use]
pub fn tabs(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(
        rows,
        format,
        no_headers,
        &["ID", "WINDOW", "TITLE", "PANES", "FOCUSED", "BADGE"],
        &|row| {
            vec![
                string(row, "id"),
                string(row, "windowId"),
                string(row, "title"),
                integer(row, "paneCount"),
                marker(row, "focused"),
                string(row, "badge"),
            ]
        },
    )
}

/// `panes` — `ID · TAB · TITLE · KIND · FOCUSED · CWD`.
#[must_use]
pub fn panes(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(
        rows,
        format,
        no_headers,
        &["ID", "TAB", "TITLE", "KIND", "FOCUSED", "CWD"],
        &|row| {
            vec![
                string(row, "id"),
                string(row, "tabId"),
                string(row, "title"),
                string(row, "kind"),
                marker(row, "focused"),
                string(row, "cwd"),
            ]
        },
    )
}

/// `font list` — `FAMILY · MONOSPACE · SCOPE`.
#[must_use]
pub fn fonts(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(
        rows,
        format,
        no_headers,
        &["FAMILY", "MONOSPACE", "SCOPE"],
        &|row| {
            vec![
                string(row, "family"),
                if boolean(row, "monospace") { "mono" } else { "" }.to_owned(),
                if boolean(row, "system") { "system" } else { "user" }.to_owned(),
            ]
        },
    )
}

/// `keybind list` — `ACTION · KEYS`.
#[must_use]
pub fn keybinds(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(rows, format, no_headers, &["ACTION", "KEYS"], &|row| {
        vec![string(row, "action"), string(row, "keys")]
    })
}

/// `config show` — `KEY · VALUE`.
#[must_use]
pub fn config(rows: &[Row], format: OutputFormat, no_headers: bool) -> String {
    render(rows, format, no_headers, &["KEY", "VALUE"], &|row| {
        vec![string(row, "key"), string(row, "value")]
    })
}

/// The shared shape of every per-list formatter: JSON passes the rows through, text picks columns.
fn render(
    rows: &[Row],
    format: OutputFormat,
    no_headers: bool,
    headers: &[&str],
    cells: &dyn Fn(&Row) -> Vec<String>,
) -> String {
    if format == OutputFormat::Json {
        return render_json(rows);
    }
    let table: Vec<Vec<String>> = rows.iter().map(cells).collect();
    render_table(headers, &table, no_headers)
}

/// Renders an aligned column table.
///
/// Every column but the last is padded to its widest cell — the header counts toward that width
/// unless `no_headers` — and the last column is unpadded, with trailing whitespace trimmed so an
/// empty final cell leaves no dangling spaces. Returns the joined lines WITHOUT a trailing newline;
/// the caller appends one. With `no_headers` and no rows the result is empty.
#[must_use]
pub fn render_table(headers: &[&str], rows: &[Vec<String>], no_headers: bool) -> String {
    let columns = headers.len();
    let mut widths = vec![0_usize; columns];
    if !no_headers {
        for (index, header) in headers.iter().enumerate() {
            if let Some(width) = widths.get_mut(index) {
                *width = header.chars().count();
            }
        }
    }
    for row in rows {
        for (index, cell) in row.iter().enumerate().take(columns) {
            if let Some(width) = widths.get_mut(index) {
                *width = (*width).max(cell.chars().count());
            }
        }
    }

    let mut lines: Vec<String> = Vec::with_capacity(rows.len() + 1);
    if !no_headers {
        let header_cells: Vec<String> = headers.iter().map(|header| (*header).to_owned()).collect();
        lines.push(format_row(&header_cells, &widths, columns));
    }
    for row in rows {
        lines.push(format_row(row, &widths, columns));
    }
    lines.join("\n")
}

/// Renders a value as a compact, key-sorted JSON line, without a trailing newline.
///
/// The compact and sorted form matches `slopdesk-ctl --json`, which is what keeps the two CLIs
/// pipe-compatible. `serde_json`'s object is a `BTreeMap`, so the sort is the encoding, not a pass
/// over it.
#[must_use]
pub fn render_json(rows: &[Row]) -> String {
    let values: Vec<Value> = rows.iter().map(|row| Value::Object(row.clone())).collect();
    serde_json::to_string(&Value::Array(values)).unwrap_or_else(|_| "[]".to_owned())
}

/// Which list a set of rows is.
///
/// The CLI's formatters differ only in their columns, so the caller names the list and this module
/// owns which columns that means — the reason the choice is an enum rather than six entry points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TableKind {
    /// `windows`.
    Windows,
    /// `tabs`.
    Tabs,
    /// `panes`.
    Panes,
    /// `font list`.
    Fonts,
    /// `keybind list`.
    Keybinds,
    /// `config show`.
    Config,
}

/// Renders one list straight from the JSON text the control socket answered with.
///
/// Rows that are not objects are dropped rather than trapping, and text that is not a JSON array at
/// all renders as no rows: these describe panes whose titles a foreign program drew into a PTY, so
/// a surprising shape is a Tuesday.
#[must_use]
pub fn table(kind: TableKind, rows_json: &str, format: OutputFormat, no_headers: bool) -> String {
    let rows: Vec<Row> = serde_json::from_str::<Value>(rows_json)
        .ok()
        .and_then(|value| {
            match value {
                Value::Array(items) => Some(items),
                _ => None,
            }
        })
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| {
            match item {
                Value::Object(row) => Some(row),
                _ => None,
            }
        })
        .collect();
    match kind {
        TableKind::Windows => windows(&rows, format, no_headers),
        TableKind::Tabs => tabs(&rows, format, no_headers),
        TableKind::Panes => panes(&rows, format, no_headers),
        TableKind::Fonts => fonts(&rows, format, no_headers),
        TableKind::Keybinds => keybinds(&rows, format, no_headers),
        TableKind::Config => config(&rows, format, no_headers),
    }
}

/// Renders an aligned table from JSON texts: an array of header strings, and an array of row
/// arrays of strings. The general renderer, for the lists a subcommand builds itself.
#[must_use]
pub fn table_from_json(headers_json: &str, rows_json: &str, no_headers: bool) -> String {
    let headers = string_list(headers_json);
    let borrowed: Vec<&str> = headers.iter().map(String::as_str).collect();
    let rows: Vec<Vec<String>> = serde_json::from_str::<Value>(rows_json)
        .ok()
        .and_then(|value| {
            match value {
                Value::Array(items) => Some(items),
                _ => None,
            }
        })
        .unwrap_or_default()
        .iter()
        .map(|item| string_list(&item.to_string()))
        .collect();
    render_table(&borrowed, &rows, no_headers)
}

/// The strings of a JSON array, with anything that is not a string dropped.
fn string_list(json: &str) -> Vec<String> {
    serde_json::from_str::<Value>(json)
        .ok()
        .and_then(|value| {
            match value {
                Value::Array(items) => Some(items),
                _ => None,
            }
        })
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| {
            match item {
                Value::String(text) => Some(text),
                _ => None,
            }
        })
        .collect()
}

/// Re-emits any JSON text compact and key-sorted, without a trailing newline.
///
/// The list formatters take rows, but the CLI also prints whole `result` objects straight through
/// — an `ipc` reply, a captured pane, a features map. Those go out in the same compact, sorted
/// spelling, so a script can pipe either kind. Text that is not JSON at all degrades to `[]`, which
/// is what the caller printed before: a surprising response shape is a Tuesday, not an exception.
#[must_use]
pub fn render_json_text(raw: &str) -> String {
    serde_json::from_str::<Value>(raw)
        .ok()
        .and_then(|value| serde_json::to_string(&value).ok())
        .unwrap_or_else(|| "[]".to_owned())
}

/// One table line: every column but the last padded, then the trailing spaces trimmed.
fn format_row(cells: &[String], widths: &[usize], columns: usize) -> String {
    let mut parts: Vec<String> = Vec::with_capacity(columns);
    for index in 0..columns {
        let cell = cells.get(index).map_or("", String::as_str);
        if index + 1 == columns {
            parts.push(cell.to_owned()); // the last column is never padded
        } else {
            parts.push(pad(cell, widths.get(index).copied().unwrap_or(0)));
        }
    }
    let line = parts.join("  ");
    line.trim_end_matches(' ').to_owned()
}

/// Left-justifies `text` to `width`.
///
/// Width is counted in `char`s. The Swift counted grapheme clusters and neither is the terminal's
/// own answer — that is display width, where one CJK glyph is two columns — so the two disagree
/// only on combining sequences inside a title or cwd. That is a cosmetic column wobble in a
/// human-readable table, and not worth a Unicode-segmentation dependency in a binary whose cost is
/// startup. `slopdesk-ctl` made the same trade next door.
fn pad(text: &str, width: usize) -> String {
    let len = text.chars().count();
    if len >= width {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len() + (width - len));
    out.push_str(text);
    out.extend(core::iter::repeat_n(' ', width - len));
    out
}

/// A string field, or an empty cell.
fn string(row: &Row, key: &str) -> String {
    row.get(key).and_then(Value::as_str).unwrap_or("").to_owned()
}

/// An integer field the host may have written as a JSON integer or as a whole float.
///
/// Foundation's `as? Int` accepted both, because an `NSNumber` bridges on exact value rather than
/// on how the number was spelled. `as_i64` alone would reject `3.0` and blank a cell that read `3`.
fn integer(row: &Row, key: &str) -> String {
    let Some(Value::Number(number)) = row.get(key) else {
        return String::new();
    };
    if let Some(exact) = number.as_i64() {
        return exact.to_string();
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "guarded: finite, whole, and inside i64's exactly-representable range"
    )]
    number
        .as_f64()
        .filter(|value| value.is_finite() && value.fract() == 0.0 && value.abs() < 9.007_199_254_740_992e15)
        .map_or_else(String::new, |value| (value as i64).to_string())
}

/// A boolean field, defaulting to false.
fn boolean(row: &Row, key: &str) -> bool {
    row.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// A current-item marker for boolean state columns: `*` when true, else empty.
fn marker(row: &Row, key: &str) -> String {
    if boolean(row, key) { "*" } else { "" }.to_owned()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::json;

    use super::{Row, config, fonts, keybinds, panes, render_table, tabs, windows};
    use crate::args::OutputFormat;

    /// Builds a row from a JSON object literal.
    fn row(value: &serde_json::Value) -> Row {
        value.as_object().expect("an object literal").clone()
    }

    #[test]
    fn a_table_pads_every_column_but_the_last() {
        let rows = vec![
            vec!["a".to_owned(), "long-value".to_owned(), "x".to_owned()],
            vec!["bbbb".to_owned(), "v".to_owned(), "y".to_owned()],
        ];
        let text = render_table(&["ID", "NAME", "F"], &rows, false);
        assert_eq!(
            text,
            "ID    NAME        F\na     long-value  x\nbbbb  v           y"
        );
    }

    #[test]
    fn an_empty_last_cell_leaves_no_dangling_spaces() {
        let rows = vec![vec!["a".to_owned(), String::new()]];
        let text = render_table(&["ID", "FOCUSED"], &rows, true);
        assert_eq!(text, "a");
        assert!(!text.contains("  "));
    }

    #[test]
    fn no_headers_and_no_rows_is_the_empty_string() {
        assert_eq!(render_table(&["ID"], &[], true), "");
        // With headers, the header line survives an empty row set.
        assert_eq!(render_table(&["ID", "NAME"], &[], false), "ID  NAME");
    }

    #[test]
    fn without_headers_the_header_text_does_not_set_the_column_width() {
        let rows = vec![vec!["a".to_owned(), "b".to_owned()]];
        assert_eq!(render_table(&["LONGHEADER", "X"], &rows, true), "a  b");
    }

    #[test]
    fn a_short_row_is_padded_out_to_the_column_count() {
        let rows = vec![vec!["only".to_owned()]];
        assert_eq!(render_table(&["A", "B", "C"], &rows, true), "only");
    }

    #[test]
    fn the_table_never_ends_with_a_newline() {
        let rows = vec![vec!["a".to_owned(), "b".to_owned()]];
        assert!(!render_table(&["A", "B"], &rows, false).ends_with('\n'));
    }

    #[test]
    fn each_list_picks_its_documented_columns() {
        let text = windows(
            &[row(
                &json!({"id": "w1", "title": "Main", "tabCount": 3, "focused": true}),
            )],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "w1  Main  3  *");

        let text = tabs(
            &[row(
                &json!({"id": "t1", "windowId": "w1", "title": "edit", "paneCount": 2, "focused": false, "badge": "3"}),
            )],
            OutputFormat::Text,
            true,
        );
        // The unfocused tab's FOCUSED cell is empty and its column is zero-wide, so PANES and BADGE
        // are separated by the two separators alone.
        assert_eq!(text, "t1  w1  edit  2    3");

        let text = panes(
            &[row(
                &json!({"id": "p1", "tabId": "t1", "title": "zsh", "kind": "terminal", "focused": true, "cwd": "/tmp"}),
            )],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "p1  t1  zsh  terminal  *  /tmp");

        let text = keybinds(
            &[row(&json!({"action": "new-tab", "keys": "cmd+t"}))],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "new-tab  cmd+t");

        let text = config(
            &[row(&json!({"key": "font-size", "value": "14"}))],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "font-size  14");
    }

    #[test]
    fn the_font_scope_column_says_system_or_user_rather_than_a_boolean() {
        let text = fonts(
            &[
                row(&json!({"family": "Menlo", "monospace": true, "system": true})),
                row(&json!({"family": "Papyrus", "monospace": false, "system": false})),
            ],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "Menlo    mono  system\nPapyrus        user");
    }

    #[test]
    fn a_missing_or_wrong_typed_field_renders_an_empty_cell_rather_than_trapping() {
        let text = panes(
            &[row(&json!({"id": 7, "title": null, "focused": "yes"}))],
            OutputFormat::Text,
            true,
        );
        // `id` is a number where a string was expected, `focused` a string where a bool was: both blank.
        assert_eq!(text, "");
    }

    #[test]
    fn a_count_written_as_a_whole_float_still_prints_as_an_integer() {
        let text = windows(
            &[row(
                &json!({"id": "w1", "title": "t", "tabCount": 3.0, "focused": false}),
            )],
            OutputFormat::Text,
            true,
        );
        assert_eq!(text, "w1  t  3");
    }

    #[test]
    fn a_fractional_or_absurd_count_blanks_rather_than_rounding_silently() {
        for value in [json!(3.5), json!(1e300), json!("3")] {
            let text = windows(
                &[row(
                    &json!({"id": "w1", "title": "t", "tabCount": value, "focused": false}),
                )],
                OutputFormat::Text,
                true,
            );
            assert_eq!(text, "w1  t");
        }
    }

    #[test]
    fn json_output_is_compact_and_key_sorted_so_the_two_clis_pipe_together() {
        let text = windows(
            &[row(&json!({"title": "Main", "id": "w1", "focused": true}))],
            OutputFormat::Json,
            false,
        );
        assert_eq!(text, r#"[{"focused":true,"id":"w1","title":"Main"}]"#);
        // `--no-headers` is a text-only concern and cannot change the JSON.
        assert_eq!(
            windows(
                &[row(&json!({"title": "Main", "id": "w1", "focused": true}))],
                OutputFormat::Json,
                true
            ),
            text
        );
    }

    #[test]
    fn json_output_of_nothing_is_an_empty_array() {
        assert_eq!(windows(&[], OutputFormat::Json, false), "[]");
    }

    #[test]
    fn a_title_a_foreign_program_drew_is_escaped_rather_than_breaking_the_line() {
        let text = panes(
            &[row(&json!({"id": "p1", "title": "he said \"hi\"\n\u{1B}[0m"}))],
            OutputFormat::Json,
            false,
        );
        assert!(text.contains(r#"\"hi\""#), "{text}");
        assert!(!text.contains('\n'), "{text}");
        assert!(!text.contains('\u{1B}'), "{text}");
    }
}
