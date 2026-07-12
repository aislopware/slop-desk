import SlopDeskCLICore
import XCTest

// Hang-safe tests for the `slopdesk` CLI list/inspect formatting. PURE: the
// table + JSON renderers are exercised directly with constructed row dicts — no socket, no GUI. The
// goldens are authored independently of the renderer's own derivation (column layout + padding +
// markers), so a formatting regression FAILS here.

final class CLIFormattingTests: XCTestCase {
    // MARK: - renderTable (low-level)

    func testRenderTableAlignsColumns() {
        let out = CLIFormatting.renderTable(
            headers: ["NAME", "AGE"],
            rows: [["Bob", "3"], ["Alice", "12"]],
            noHeaders: false,
        )
        XCTAssertEqual(out, "NAME   AGE\nBob    3\nAlice  12")
    }

    func testRenderTableNoHeadersDropsHeaderRow() {
        let out = CLIFormatting.renderTable(headers: ["NAME", "AGE"], rows: [["Bob", "3"]], noHeaders: true)
        XCTAssertEqual(out, "Bob  3")
    }

    func testRenderTableTrimsTrailingEmptyFinalCell() {
        // An empty last column must not leave dangling spaces.
        let out = CLIFormatting.renderTable(headers: ["A", "B"], rows: [["x", ""]], noHeaders: true)
        XCTAssertEqual(out, "x")
    }

    func testRenderTableEmptyRowsKeepsHeader() {
        XCTAssertEqual(CLIFormatting.renderTable(headers: ["A", "B"], rows: [], noHeaders: false), "A  B")
        XCTAssertEqual(CLIFormatting.renderTable(headers: ["A", "B"], rows: [], noHeaders: true), "")
    }

    // MARK: - renderJSON

    func testRenderJSONIsCompactAndKeySorted() {
        XCTAssertEqual(CLIFormatting.renderJSON([["b": 2, "a": 1]]), #"[{"a":1,"b":2}]"#)
    }

    func testRenderJSONEmptyArray() {
        XCTAssertEqual(CLIFormatting.renderJSON([]), "[]")
    }

    func testRenderJSONInvalidObjectDegradesToEmpty() {
        // A non-JSON leaf (a Date) is not a valid JSON object → safe "[]" rather than a trap.
        XCTAssertEqual(CLIFormatting.renderJSON([["when": Date()]]), "[]")
    }

    // MARK: - windows

    func testWindowsTextGolden() {
        let rows: [[String: Any]] = [["id": "w1", "title": "Main", "tabCount": 2, "focused": true]]
        XCTAssertEqual(
            CLIFormatting.windows(rows, format: .text, noHeaders: false),
            "ID  TITLE  TABS  FOCUSED\nw1  Main   2     *",
        )
    }

    func testWindowsNotFocusedNoHeaders() {
        let rows: [[String: Any]] = [["id": "w2", "title": "X", "tabCount": 0, "focused": false]]
        // No header row; not-focused → no `*`; the trailing empty FOCUSED cell is trimmed.
        XCTAssertEqual(CLIFormatting.windows(rows, format: .text, noHeaders: true), "w2  X  0")
    }

    func testWindowsMissingFieldsRenderEmptyCellsNoCrash() {
        let rows: [[String: Any]] = [["id": "w1"]] // title/tabCount/focused absent
        XCTAssertEqual(CLIFormatting.windows(rows, format: .text, noHeaders: true), "w1")
    }

    func testWindowsJSONMatchesRenderJSON() {
        let rows: [[String: Any]] = [["id": "w1", "title": "Main", "tabCount": 2, "focused": true]]
        XCTAssertEqual(
            CLIFormatting.windows(rows, format: .json, noHeaders: false),
            CLIFormatting.renderJSON(rows),
        )
    }

    // MARK: - tabs

    func testTabsBadgeColumn() {
        let rows: [[String: Any]] = [
            ["id": "t1", "windowId": "w1", "title": "A", "paneCount": 2, "focused": true, "badge": "running"],
        ]
        let out = CLIFormatting.tabs(rows, format: .text, noHeaders: false)
        XCTAssertTrue(out.contains("BADGE"))
        XCTAssertTrue(out.contains("running"))
        // Focused tab is marked with `*`.
        XCTAssertTrue(out.contains("*"))
    }

    func testTabsMissingBadgeIsEmptyNotCrash() {
        let rows: [[String: Any]] = [
            ["id": "t2", "windowId": "w1", "title": "B", "paneCount": 1, "focused": false],
        ]
        let out = CLIFormatting.tabs(rows, format: .text, noHeaders: true)
        XCTAssertEqual(out, "t2  w1  B  1")
    }

    // MARK: - panes

    func testPanesKindAndCwd() {
        let rows: [[String: Any]] = [
            ["id": "p1", "tabId": "t1", "title": "sh", "kind": "terminal", "focused": true, "cwd": "/tmp"],
        ]
        let out = CLIFormatting.panes(rows, format: .text, noHeaders: false)
        XCTAssertTrue(out.contains("KIND"))
        XCTAssertTrue(out.contains("terminal"))
        XCTAssertTrue(out.contains("/tmp"))
    }

    // MARK: - themes

    func testThemesAppearanceLightActiveMarker() {
        let rows: [[String: Any]] = [["name": "Paper", "dark": false, "active": true]]
        let out = CLIFormatting.themes(rows, format: .text, noHeaders: false)
        XCTAssertTrue(out.contains("APPEARANCE"))
        XCTAssertTrue(out.contains("Paper"))
        XCTAssertTrue(out.contains("light"))
        XCTAssertTrue(out.contains("*"))
    }

    func testThemesDarkInactiveNoHeaders() {
        let rows: [[String: Any]] = [["name": "Night", "dark": true, "active": false]]
        XCTAssertEqual(CLIFormatting.themes(rows, format: .text, noHeaders: true), "Night  dark")
    }

    // MARK: - fonts

    func testFontsMonoSystemScope() {
        let rows: [[String: Any]] = [["family": "Menlo", "monospace": true, "system": true]]
        XCTAssertEqual(CLIFormatting.fonts(rows, format: .text, noHeaders: true), "Menlo  mono  system")
    }

    func testFontsNonMonoUserScope() {
        let rows: [[String: Any]] = [["family": "Arial", "monospace": false, "system": false]]
        let out = CLIFormatting.fonts(rows, format: .text, noHeaders: true)
        XCTAssertTrue(out.contains("user"))
        XCTAssertFalse(out.contains("mono"))
        XCTAssertFalse(out.contains("system"))
    }

    // MARK: - keybinds

    func testKeybindsColumns() {
        let rows: [[String: Any]] = [["action": "newTab", "keys": "⌘T"]]
        XCTAssertEqual(
            CLIFormatting.keybinds(rows, format: .text, noHeaders: false),
            "ACTION  KEYS\nnewTab  ⌘T",
        )
    }

    // MARK: - config

    func testConfigColumns() {
        let rows: [[String: Any]] = [["key": "theme", "value": "Monokai"]]
        XCTAssertEqual(
            CLIFormatting.config(rows, format: .text, noHeaders: false),
            "KEY    VALUE\ntheme  Monokai",
        )
    }

    func testConfigJSONMatchesRenderJSON() {
        let rows: [[String: Any]] = [["key": "theme", "value": "Monokai"], ["key": "font-size", "value": "14"]]
        XCTAssertEqual(
            CLIFormatting.config(rows, format: .json, noHeaders: false),
            CLIFormatting.renderJSON(rows),
        )
    }
}
