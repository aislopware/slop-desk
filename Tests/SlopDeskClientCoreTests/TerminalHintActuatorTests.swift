// TerminalHintActuatorTests — the two Hint Mode decisions, separated from their actuation.
//
// The interesting one is the custom `hint-pattern` template, because it decides where an ARBITRARY
// string runs. The default is the host shell, verbatim down the PTY; the single exception is an
// `open <url>` whose argument really is a URL with a scheme, which opens on the CLIENT because the
// host has no browser the user is looking at. `open ./notes` is NOT that exception — it is a shell
// command about a host-local file, and sending it to the client would open the wrong machine's file
// (or nothing). That one character of difference is why the rule is a value now.
//
// The intent→``LinkAction`` map is the second: Hint-to-Open is an EXPLICIT open, so it must route
// through the config-independent policy rather than the configurable ⌘click gesture — under
// `link-cmd-click = nothing` the gesture path would make ⌘⇧J do nothing at all.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class TerminalHintActuatorTests: XCTestCase {
    private func pathLink(_ raw: String = "/a/b/file.txt") -> DetectedLink {
        DetectedLink(
            row: 0, colStart: 0, colEnd: raw.count, kind: .absolutePath,
            raw: raw, resolvedAbsolute: raw,
        )
    }

    // MARK: - The custom-template rule

    /// NO TEMPLATE COPIES. A `hint-pattern` with no action is a pattern the user only wanted to grab
    /// text with, and copying is the safest thing a hint can do.
    func testAnAbsentOrEmptyTemplateCopiesTheMatch() {
        XCTAssertEqual(TerminalHintActuator.customAction(template: nil, raw: "PROJ-42"), .copyRaw)
        XCTAssertEqual(TerminalHintActuator.customAction(template: "", raw: "PROJ-42"), .copyRaw)
    }

    /// `{0}` is substituted FIRST, anywhere in the line — including inside an `open` argument, which
    /// is how a pattern turns a ticket id into a URL.
    func testTheMatchIsSubstitutedAnywhereInTheTemplate() {
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "git show {0} | head -40", raw: "abc123"),
            .runOnHost("git show abc123 | head -40"),
        )
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "open https://tracker/{0}", raw: "PROJ-42"),
            .openURLClient("https://tracker/PROJ-42"),
        )
    }

    /// THE SCHEME IS THE TEST, not the `open ` prefix. `URL(string:)` accepts almost anything, so a
    /// shell `open` of a host-local path has to stay on the host — opening it on the client would
    /// address the wrong machine's filesystem.
    func testOnlyAnOpenOfARealURLLeavesTheHost() {
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "open ./notes.md", raw: "x"),
            .runOnHost("open ./notes.md"),
            "a relative path has no scheme — this is a host shell command",
        )
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "open /tmp/report.pdf", raw: "x"),
            .runOnHost("open /tmp/report.pdf"),
        )
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "open  https://example.com  ", raw: "x"),
            .openURLClient("https://example.com"),
            "the argument is trimmed before it is judged",
        )
        XCTAssertEqual(
            TerminalHintActuator.customAction(template: "openhttps://example.com", raw: "x"),
            .runOnHost("openhttps://example.com"),
            "`open` without its space is some other command entirely",
        )
    }

    // MARK: - The intent map

    /// Hint-to-OPEN is an EXPLICIT open: it must resolve to the best handler regardless of how the
    /// user configured the ⌘click GESTURE, or `link-cmd-click = nothing` would make the chord inert.
    func testHintToOpenIsExplicitRatherThanTheConfigurableGesture() {
        let link = pathLink()
        XCTAssertEqual(
            TerminalHintActuator.linkAction(for: .open, link: link),
            LinkActionPolicy.explicitOpenAction(link: link),
        )
        XCTAssertEqual(
            TerminalHintActuator.linkAction(for: .copy, link: link),
            LinkActionPolicy.action(for: .copyPath, link: link),
        )
        XCTAssertEqual(
            TerminalHintActuator.linkAction(for: .reveal, link: link),
            LinkActionPolicy.action(for: .revealInFinder, link: link),
        )
    }
}
