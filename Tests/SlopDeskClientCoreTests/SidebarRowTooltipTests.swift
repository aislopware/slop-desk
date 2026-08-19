// SidebarRowTooltipTests — pins `SidebarRowTooltip.text(cwd:detail:lastCommand:)`, the sidebar row
// tooltip builder (full cwd + untruncated prose readout + last-command line, empty parts
// omitted), and `commandLine(_:)`, the `command · duration · exit N` assembly. A raw `\(cwd)`
// interpolation of a `String?` renders the literal `Optional(...)` wrapper — this pins the unwrapped
// form instead.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class SidebarRowTooltipTests: XCTestCase {
    /// All three parts present: three lines, cwd first, NEVER `Optional(...)`.
    func testAllPartsJoinAsLines() {
        let text = SidebarRowTooltip.text(
            cwd: "/Users/me/project",
            detail: "Allow edit to Config.swift?",
            lastCommand: "make check · 1.3s · exit 0",
        )
        XCTAssertEqual(text, "/Users/me/project\nAllow edit to Config.swift?\nmake check · 1.3s · exit 0")
    }

    /// A cwd-less pane with a readout detail: just the detail — no blank line, no literal "nil".
    func testNilCwdOmitsItsLineEntirely() {
        let text = SidebarRowTooltip.text(cwd: nil, detail: "writing tests", lastCommand: nil)
        XCTAssertEqual(text, "writing tests")
    }

    /// No detail and no command line: the tooltip is the plain cwd.
    func testCwdOnlyFallsBackToPlainCwd() {
        let text = SidebarRowTooltip.text(cwd: "/Users/me/project", detail: nil, lastCommand: nil)
        XCTAssertEqual(text, "/Users/me/project")
    }

    /// Nothing at all: `nil` (the caller's `.help(helpText ?? "")` renders no tooltip).
    func testAllNilIsNil() {
        XCTAssertNil(SidebarRowTooltip.text(cwd: nil, detail: nil, lastCommand: nil))
    }

    /// An empty-string part is treated as absent, same as `nil` — no stray blank lines.
    func testEmptyPartsAreOmitted() {
        let text = SidebarRowTooltip.text(cwd: "", detail: "answering", lastCommand: "")
        XCTAssertEqual(text, "answering")
    }

    // MARK: - Who else is on this pane

    /// VIEWING and HOLDING are different facts and the tooltip says both, in that order: who has
    /// the pane on screen, then whose channel is on its PTY.
    func testViewersAndHoldersRenderAsSeparateLines() {
        let text = SidebarRowTooltip.text(
            cwd: "/Users/me/project",
            detail: nil,
            lastCommand: nil,
            viewers: ["iPad"],
            holders: ["mac-studio"],
        )
        XCTAssertEqual(text, "/Users/me/project\nAlso open on iPad\nHeld by mac-studio")
    }

    /// Several holders read as a list — two Macs and a phone on one nvim is the whole point of the
    /// fan-out, and the tooltip has to name all of them.
    func testSeveralHoldersJoinWithCommas() {
        let text = SidebarRowTooltip.text(
            cwd: nil, detail: nil, lastCommand: nil, holders: ["mac-studio", "macbook-pro"],
        )
        XCTAssertEqual(text, "Held by mac-studio, macbook-pro")
    }

    /// The common case: this client alone holds the pane, so the line is absent rather than empty.
    func testNoHoldersRendersNoLine() {
        let text = SidebarRowTooltip.text(cwd: "/Users/me/project", detail: nil, lastCommand: nil)
        XCTAssertEqual(text, "/Users/me/project")
    }

    // MARK: - The last-command line

    /// A finished block: `command · duration · exit N`.
    func testCommandLineJoinsCommandDurationExit() {
        let block = CommandBlock(
            index: 3, commandText: "make check", exitCode: 0, durationMS: 1300, complete: true,
        )
        XCTAssertEqual(SidebarRowTooltip.commandLine(block), "make check · 1.3s · exit 0")
    }

    /// A failed block keeps its non-zero exit in the line.
    func testCommandLineCarriesFailureExit() {
        let block = CommandBlock(
            index: 4, commandText: "npm test", exitCode: 137, durationMS: 250, complete: true,
        )
        XCTAssertEqual(SidebarRowTooltip.commandLine(block), "npm test · 250ms · exit 137")
    }

    /// A blank command (a bare-Enter cycle) omits the command part rather than leading with a dot.
    func testCommandLineOmitsBlankCommand() {
        let block = CommandBlock(index: 5, commandText: "  ", exitCode: 0, durationMS: 90, complete: true)
        XCTAssertEqual(SidebarRowTooltip.commandLine(block), "90ms · exit 0")
    }
}
