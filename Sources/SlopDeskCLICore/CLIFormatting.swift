import Foundation

// `slopdesk` list/inspect output formatting. PURE: every formatter is a
// deterministic value transform over the decoded NDJSON `result` rows — no socket, no I/O — so the
// whole table/JSON surface is exhaustively unit-tested without a running app (hang-safety rule).
//
// The CLI renders list output as an aligned column table by default and as structured JSON under
// `--json` / `--format json` (for scripting); `--no-headers` strips the header row for piping. The
// per-list helpers (`windows`/`tabs`/`panes`/`themes`/`fonts`/`keybinds`/`config`)
// pick the columns + cell formatting; ``renderTable(headers:rows:noHeaders:)`` and
// ``renderJSON(_:)`` are the shared low-level renderers.
//
// Validate-then-drop on the row dicts (they arrive over the control socket): a missing or
// wrong-typed field renders as an empty cell rather than trapping — the CLI never crashes on a
// surprising response shape (CLAUDE.md untrusted-input contract).

public enum CLIFormatting {
    // MARK: - Per-list formatters

    /// `windows` → `ID · TITLE · TABS · FOCUSED` (focused marked `*`).
    public static func windows(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["ID", "TITLE", "TABS", "FOCUSED"],
            rows: rows.map { [string($0, "id"), string($0, "title"), integer($0, "tabCount"), marker($0, "focused")] },
            noHeaders: noHeaders,
        )
    }

    /// `tabs` → `ID · WINDOW · TITLE · PANES · FOCUSED · BADGE`.
    public static func tabs(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["ID", "WINDOW", "TITLE", "PANES", "FOCUSED", "BADGE"],
            rows: rows.map {
                [
                    string($0, "id"), string($0, "windowId"), string($0, "title"),
                    integer($0, "paneCount"), marker($0, "focused"), string($0, "badge"),
                ]
            },
            noHeaders: noHeaders,
        )
    }

    /// `panes` → `ID · TAB · TITLE · KIND · FOCUSED · CWD`.
    public static func panes(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["ID", "TAB", "TITLE", "KIND", "FOCUSED", "CWD"],
            rows: rows.map {
                [
                    string($0, "id"), string($0, "tabId"), string($0, "title"),
                    string($0, "kind"), marker($0, "focused"), string($0, "cwd"),
                ]
            },
            noHeaders: noHeaders,
        )
    }

    /// `theme list` → `NAME · APPEARANCE · ACTIVE` (`dark`/`light`; active marked `*`).
    public static func themes(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["NAME", "APPEARANCE", "ACTIVE"],
            rows: rows.map { [string($0, "name"), bool($0, "dark") ? "dark" : "light", marker($0, "active")] },
            noHeaders: noHeaders,
        )
    }

    /// `font list` → `FAMILY · MONOSPACE · SCOPE` (`mono` when fixed-pitch; `system`/`user`).
    public static func fonts(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["FAMILY", "MONOSPACE", "SCOPE"],
            rows: rows.map {
                [string($0, "family"), bool($0, "monospace") ? "mono" : "", bool($0, "system") ? "system" : "user"]
            },
            noHeaders: noHeaders,
        )
    }

    /// `keybind list` → `ACTION · KEYS`.
    public static func keybinds(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["ACTION", "KEYS"],
            rows: rows.map { [string($0, "action"), string($0, "keys")] },
            noHeaders: noHeaders,
        )
    }

    /// `config show` → `KEY · VALUE`.
    public static func config(_ rows: [[String: Any]], format: CLIOutputFormat, noHeaders: Bool) -> String {
        if format == .json { return renderJSON(rows) }
        return renderTable(
            headers: ["KEY", "VALUE"],
            rows: rows.map { [string($0, "key"), string($0, "value")] },
            noHeaders: noHeaders,
        )
    }

    // MARK: - Low-level renderers

    /// Render an aligned column table. Every column except the last is left-padded to its widest cell
    /// (the header counts toward the width unless `noHeaders`); the last column is unpadded and any
    /// trailing whitespace is trimmed so an empty final cell leaves no dangling spaces. Returns the
    /// joined lines WITHOUT a trailing newline (the caller appends one). With `noHeaders` and no rows
    /// the result is the empty string.
    public static func renderTable(headers: [String], rows: [[String]], noHeaders: Bool) -> String {
        let columns = headers.count
        var widths = [Int](repeating: 0, count: columns)
        if !noHeaders {
            for (i, header) in headers.enumerated() { widths[i] = header.count }
        }
        for row in rows {
            for i in 0..<columns where i < row.count {
                widths[i] = max(widths[i], row[i].count)
            }
        }
        var lines: [String] = []
        if !noHeaders { lines.append(formatRow(headers, widths: widths, columns: columns)) }
        for row in rows { lines.append(formatRow(row, widths: widths, columns: columns)) }
        return lines.joined(separator: "\n")
    }

    /// Render `value` as a compact, deterministically-key-sorted JSON line (no trailing newline). The
    /// compact + sorted form matches `slopdesk-ctl --json` so the two CLIs are pipe-compatible. A
    /// value that is not a valid JSON object (should not happen for list payloads) degrades to `[]`.
    public static func renderJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(bytes: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    // MARK: - Private helpers

    private static func formatRow(_ cells: [String], widths: [Int], columns: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(columns)
        for i in 0..<columns {
            let cell = i < cells.count ? cells[i] : ""
            if i == columns - 1 {
                parts.append(cell) // last column is never padded
            } else {
                parts.append(pad(cell, to: widths[i]))
            }
        }
        var line = parts.joined(separator: "  ")
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    /// Left-justify `s` to `width` using grapheme `count` (consistent with the width measurement).
    private static func pad(_ s: String, to width: Int) -> String {
        let deficit = width - s.count
        return deficit > 0 ? s + String(repeating: " ", count: deficit) : s
    }

    private static func string(_ row: [String: Any], _ key: String) -> String {
        row[key] as? String ?? ""
    }

    private static func integer(_ row: [String: Any], _ key: String) -> String {
        if let i = row[key] as? Int { return String(i) }
        if let d = row[key] as? Double { return String(Int(d)) }
        return ""
    }

    private static func bool(_ row: [String: Any], _ key: String) -> Bool {
        row[key] as? Bool ?? false
    }

    /// A current-item marker for boolean state columns (FOCUSED / ACTIVE): `*` when true, else empty.
    private static func marker(_ row: [String: Any], _ key: String) -> String {
        bool(row, key) ? "*" : ""
    }
}
