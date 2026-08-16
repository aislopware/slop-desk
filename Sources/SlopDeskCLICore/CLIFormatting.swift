import CSlopDeskFFI
import Foundation

// `slopdesk` list/inspect output formatting — the Swift face of `rust/slopdesk-cli`'s `formatting`.
//
// The CLI renders list output as an aligned column table by default and as structured JSON under
// `--json` / `--format json` (for scripting); `--no-headers` strips the header row for piping.
// Which columns each list has, how a cell is spelled, how a table is padded and how JSON is sorted
// are all the crate's.
//
// The rows cross as JSON TEXT, which is the shape they arrived in: the control socket answers
// NDJSON, so re-encoding a decoded row dictionary is the cheapest way to hand it over, and the
// crate already owns a JSON parser for exactly these bytes — pane titles and cwd paths a foreign
// program drew into a PTY. Validate-then-drop is unchanged: a missing or wrong-typed field renders
// as an empty cell rather than trapping.

public enum CLIFormatting {
    // MARK: - Per-list formatters

    /// `windows` → `ID · TITLE · TABS · FOCUSED` (focused marked `*`).
    public static func windows(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_WINDOWS, rows, format, noHeaders)
    }

    /// `tabs` → `ID · WINDOW · TITLE · PANES · FOCUSED · BADGE`.
    public static func tabs(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_TABS, rows, format, noHeaders)
    }

    /// `panes` → `ID · TAB · TITLE · KIND · FOCUSED · CWD`.
    public static func panes(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_PANES, rows, format, noHeaders)
    }

    /// `font list` → `FAMILY · MONOSPACE · SCOPE` (`mono` when fixed-pitch; `system`/`user`).
    public static func fonts(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_FONTS, rows, format, noHeaders)
    }

    /// `keybind list` → `ACTION · KEYS`.
    public static func keybinds(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_KEYBINDS, rows, format, noHeaders)
    }

    /// `config show` → `KEY · VALUE`.
    public static func config(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        table(SLOPDESK_CLI_TABLE_CONFIG, rows, format, noHeaders)
    }

    // MARK: - Low-level renderers

    /// Render an aligned column table. Every column except the last is left-padded to its widest cell
    /// (the header counts toward the width unless `noHeaders`); the last column is unpadded and any
    /// trailing whitespace is trimmed so an empty final cell leaves no dangling spaces. Returns the
    /// joined lines WITHOUT a trailing newline (the caller appends one). With `noHeaders` and no rows
    /// the result is the empty string.
    public static func renderTable(headers: [String], rows: [[String]], noHeaders: Bool) -> String {
        let headerJSON = Array(json(headers).utf8)
        let rowJSON = Array(json(rows).utf8)
        return headerJSON.withUnsafeBufferPointer { columns in
            rowJSON.withUnsafeBufferPointer { cells in
                CLICompletions.answer { out, cap in
                    slopdesk_cli_render_table(
                        columns.baseAddress, columns.count, cells.baseAddress, cells.count, noHeaders, out, cap,
                    )
                }
            }
        }
    }

    /// Render `value` as a compact, deterministically-key-sorted JSON line (no trailing newline). The
    /// compact + sorted form matches `slopdesk-ctl --json` so the two CLIs are pipe-compatible. A
    /// value that is not valid JSON (should not happen for list payloads) degrades to `[]`.
    public static func renderJSON(_ value: Any) -> String {
        let bytes = Array(json(value).utf8)
        return bytes.withUnsafeBufferPointer { raw in
            CLICompletions.answer { out, cap in
                slopdesk_cli_render_json(raw.baseAddress, raw.count, out, cap)
            }
        }
    }

    // MARK: - Private helpers

    /// One list rendered through the door, its rows handed over in the JSON they arrived as.
    private static func table(
        _ kind: UInt32,
        _ rows: [[String: Any]],
        _ format: CLIOutputFormat,
        _ noHeaders: Bool,
    ) -> String {
        let bytes = Array(json(rows).utf8)
        return bytes.withUnsafeBufferPointer { raw in
            CLICompletions.answer { out, cap in
                slopdesk_cli_table(kind, raw.baseAddress, raw.count, format.code, noHeaders, out, cap)
            }
        }
    }

    /// `value` re-encoded as JSON text for the crossing. A value Foundation cannot encode hands over
    /// text that is not JSON, which the door answers `[]` for — the same degradation as before.
    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(bytes: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
