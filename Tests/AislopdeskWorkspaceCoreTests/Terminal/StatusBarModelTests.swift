import XCTest
@testable import AislopdeskWorkspaceCore

/// E10 WI-4 (ES-E10-3 / ES-E10-4): the pure bottom-status-bar model. These pin the otty cwd shorthand
/// (last 1–2 components with a `…/` ellipsis), the last-exit badge classification (0 → success, non-zero →
/// failure(code), no-command → running, non-terminal → none), and the ⌘-hover full-path override precedence
/// (`full-path-hover.png`). Each case is revert-to-confirm-fail: it fails on a model that mis-truncates,
/// mis-classifies an exit, or lets the resting cwd win over a live hover.
final class StatusBarModelTests: XCTestCase {
    // MARK: - cwd truncation (otty shorthand)

    /// A deep path keeps only the last two components and marks the drop with `…/`.
    func testTruncatesDeepPathToLastTwoComponentsWithEllipsis() {
        XCTAssertEqual(StatusBarContent.truncatedCwd("/Users/abner/Workplace/otty"), "…/Workplace/otty")
    }

    /// Exactly two components keep both and add NO ellipsis (nothing was dropped).
    func testTwoComponentPathHasNoEllipsis() {
        XCTAssertEqual(StatusBarContent.truncatedCwd("/Users/abner"), "Users/abner")
    }

    /// A single component renders bare (no ellipsis, nothing dropped).
    func testSingleComponentPath() {
        XCTAssertEqual(StatusBarContent.truncatedCwd("/etc"), "etc")
    }

    /// The filesystem root collapses to `/`.
    func testRootPath() {
        XCTAssertEqual(StatusBarContent.truncatedCwd("/"), "/")
    }

    /// A trailing separator is ignored (it is not a real component).
    func testTrailingSlashIsTrimmed() {
        XCTAssertEqual(StatusBarContent.truncatedCwd("/Users/abner/Workplace/otty/"), "…/Workplace/otty")
    }

    /// An unknown (nil) or empty cwd produces the empty string (the strip shows no left text).
    func testNilAndEmptyCwd() {
        XCTAssertEqual(StatusBarContent.truncatedCwd(nil), "")
        XCTAssertEqual(StatusBarContent.truncatedCwd(""), "")
    }

    // MARK: - exit badge classification

    /// Exit 0 → success.
    func testExitZeroIsSuccess() {
        let badge = StatusBarContent.exitBadge(lastCommand: (exitCode: 0, durationMS: 12), kind: .terminal)
        XCTAssertEqual(badge, .success)
    }

    /// A non-zero exit carries the code in `.failure`.
    func testNonZeroExitIsFailureWithCode() {
        let badge = StatusBarContent.exitBadge(lastCommand: (exitCode: 130, durationMS: 12), kind: .terminal)
        XCTAssertEqual(badge, .failure(130))
    }

    /// A finished command with NO reported code is treated as success (mirrors OutlinePresentation).
    func testFinishedWithNoCodeIsSuccess() {
        let badge = StatusBarContent.exitBadge(lastCommand: (exitCode: nil, durationMS: 12), kind: .terminal)
        XCTAssertEqual(badge, .success)
    }

    /// No completed command yet → running.
    func testNoCommandIsRunning() {
        let badge = StatusBarContent.exitBadge(lastCommand: nil, kind: .terminal)
        XCTAssertEqual(badge, .running)
    }

    /// A non-terminal pane has no exit concept → none (even if a stale tuple is somehow supplied).
    func testNonTerminalKindHasNoBadge() {
        XCTAssertEqual(StatusBarContent.exitBadge(lastCommand: nil, kind: .remoteGUI), .none)
        XCTAssertEqual(
            StatusBarContent.exitBadge(lastCommand: (exitCode: 1, durationMS: 0), kind: .systemDialog),
            .none,
        )
    }

    // MARK: - make() composition + hover override precedence

    /// At rest the left field is the truncated cwd, NOT a hover, and the full cwd is the tooltip source.
    func testMakeRestingShowsTruncatedCwd() {
        let content = StatusBarContent.make(
            cwd: "/Users/abner/Workplace/otty",
            lastCommand: (exitCode: 0, durationMS: 5),
            kind: .terminal,
            host: "mac-studio",
            hoverFullPath: nil,
        )
        XCTAssertEqual(content.cwdDisplay, "…/Workplace/otty")
        XCTAssertFalse(content.isPathHover)
        XCTAssertEqual(content.fullCwd, "/Users/abner/Workplace/otty")
        XCTAssertEqual(content.exit, .success)
        XCTAssertEqual(content.paneKind, "terminal")
        XCTAssertEqual(content.host, "mac-studio")
    }

    /// ES-E10-4: a ⌘-hover OVERRIDES the resting cwd — the left field shows the FULL hovered path, flagged as
    /// a hover so the view styles the dark sub-strip. This would fail if the resting cwd won precedence.
    func testHoverOverridesRestingCwd() {
        let content = StatusBarContent.make(
            cwd: "/Users/abner/Workplace/otty",
            lastCommand: nil,
            kind: .terminal,
            host: "mac-studio",
            hoverFullPath: "/Users/abner/Workplace/otty/CREDITS.md",
        )
        XCTAssertEqual(content.cwdDisplay, "/Users/abner/Workplace/otty/CREDITS.md")
        XCTAssertTrue(content.isPathHover)
        XCTAssertEqual(content.fullCwd, "/Users/abner/Workplace/otty/CREDITS.md")
        // The exit badge is still computed under a hover (running here — no finished command).
        XCTAssertEqual(content.exit, .running)
    }

    /// An empty hover string is treated as "no hover" (validate-then-ignore) — the resting cwd is shown.
    func testEmptyHoverFallsBackToCwd() {
        let content = StatusBarContent.make(
            cwd: "/var/log",
            lastCommand: nil,
            kind: .terminal,
            host: "",
            hoverFullPath: "",
        )
        XCTAssertEqual(content.cwdDisplay, "var/log")
        XCTAssertFalse(content.isPathHover)
    }

    // MARK: - E21 WI-4 (ES-E21-2): first-class video-pane status content

    /// A `.remoteGUI` video pane is a first-class status-bar citizen: the model labels it "remote", OMITS the
    /// exit badge (a streamed window has no shell-exit concept), and leaves the cwd empty (a video pane reports
    /// no OSC-7 dir), while still threading the connection host. This pins the exact `make` composition
    /// ``GuiLeafView``'s `StatusBarStrip` mount relies on (the strip view itself is app-target / hang-unsafe to
    /// instantiate). It fails if `paneKindLabel` ever drops `.remoteGUI` or `make` starts emitting an exit / cwd
    /// for a non-terminal kind.
    func testMakeRemoteGUIPaneHasRemoteLabelNoExitEmptyCwd() {
        let content = StatusBarContent.make(
            cwd: nil,
            lastCommand: nil,
            kind: .remoteGUI,
            host: "mac-studio",
            hoverFullPath: nil,
        )
        XCTAssertEqual(content.paneKind, "remote")
        XCTAssertEqual(content.exit, .none)
        XCTAssertTrue(content.cwdDisplay.isEmpty)
        XCTAssertNil(content.fullCwd)
        XCTAssertFalse(content.isPathHover)
        XCTAssertEqual(content.host, "mac-studio")
    }

    /// A `.systemDialog` pane reads "dialog" (the system-password-dialog peer) with the same no-exit /
    /// empty-cwd shape — and even a stale `lastCommand` tuple cannot light the badge, since the non-terminal
    /// kind forces `.none` through `make` (not only through the lower-level `exitBadge`).
    func testMakeSystemDialogPaneHasDialogLabelNoExitDespiteStaleCommand() {
        let content = StatusBarContent.make(
            cwd: nil,
            lastCommand: (exitCode: 1, durationMS: 0),
            kind: .systemDialog,
            host: "",
            hoverFullPath: nil,
        )
        XCTAssertEqual(content.paneKind, "dialog")
        XCTAssertEqual(content.exit, .none)
        XCTAssertTrue(content.cwdDisplay.isEmpty)
        XCTAssertTrue(content.host.isEmpty)
    }
}
