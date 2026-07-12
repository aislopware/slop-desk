// LinkActionActuatorTests — pin the extracted `LinkActionActuator`, the ONE thin platform dispatch
// the Jump-To / Open-Quickly "Current" rows share. This is a behavior-preserving MOVE out of `JumpToView`, so
// these tests assert the *routing* the extraction must preserve (not the move itself):
//   - `.changeDirectoryPTY` injects the VERBATIM `cd <quoted>` line that falls back to the PARENT for a file
//     down the pane's `inputSink` — proven through the FULL `rowActions` → `LinkActionPolicy`
//     → `actuate` path, so a regression to a bare `cd '<file>'` flips the test (revert-to-confirm-fail);
//   - `.openHost` / `.revealHost` fire the pane model's host-RPC callbacks (verbs 9 / 10) with the raw path;
//   - `.copyPathClient` writes the CLIENT pasteboard; `.nothing` is a true no-op (no sink / callback / clip);
//   - `rowActions` keeps the `TerminalContextMenu` routing INTACT per kind: a URL offers only Open + Copy URL
//     (no Reveal / cd / SSH row), a path offers the full Open / Copy Path / Reveal / Change-Directory set, and a
//     command block offers Jump-to + Copy.
//
// macOS-gated (NSPasteboard); no window / responder / VT / Metal — hang-safe (the pasteboard-test
// idiom). `TerminalViewModel()` + a `.tree` `WorkspaceStore` are headless (mirrors `HostPathActionsTests`).

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class LinkActionActuatorTests: XCTestCase {
    // MARK: - Fixtures

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    private func urlLink(_ raw: String = "https://example.com") -> DetectedLink {
        DetectedLink(row: 0, colStart: 0, colEnd: raw.count, kind: .url, raw: raw, resolvedAbsolute: nil)
    }

    private func pathLink(_ raw: String = "/a/b/file.txt") -> DetectedLink {
        DetectedLink(row: 0, colStart: 0, colEnd: raw.count, kind: .absolutePath, raw: raw, resolvedAbsolute: raw)
    }

    // MARK: - actuate(_:model:)

    /// `.changeDirectoryPTY` injects the verbatim cd line (parent-if-file) down `inputSink` — never via
    /// `SendKeysParser`. A regression to a bare `cd '<file>'` (dropping the `|| cd '<parent>'` fallback) flips.
    func testChangeDirectoryActuationSendsVerbatimCdParentForAFile() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        model.inputSink = { sunk.append($0) }

        LinkActionActuator.actuate(.changeDirectoryPTY("/a/b/file.txt"), model: model)

        XCTAssertEqual(
            sunk,
            [Data("cd '/a/b/file.txt' 2>/dev/null || cd '/a/b'\n".utf8)],
            "cd is verbatim UTF-8 and falls back to the file's PARENT folder",
        )
    }

    /// `.openHost` fires the pane model's host-open callback (verb 9) with the raw path.
    func testOpenHostFiresHostOpenCallbackWithRawPath() {
        let model = TerminalViewModel()
        var opened: [String] = []
        model.onRequestOpenHostPath = { opened.append($0) }

        LinkActionActuator.actuate(.openHost("/Users/me/main.swift"), model: model)

        XCTAssertEqual(opened, ["/Users/me/main.swift"], "open routes to the host-open seam, raw path")
    }

    /// `.revealHost` fires the pane model's host-reveal callback (verb 10) with the raw path.
    func testRevealHostFiresHostRevealCallbackWithRawPath() {
        let model = TerminalViewModel()
        var revealed: [String] = []
        model.onRequestRevealHostPath = { revealed.append($0) }

        LinkActionActuator.actuate(.revealHost("/tmp/x"), model: model)

        XCTAssertEqual(revealed, ["/tmp/x"], "reveal routes to the host-reveal seam, raw path")
    }

    /// `.copyPathClient` writes the CLIENT pasteboard.
    func testCopyActuationWritesClientPasteboard() {
        let pb = ClientPasteboard.pasteboard
        pb.clearContents()

        LinkActionActuator.actuate(.copyPathClient("/a/b/c"), model: nil)

        XCTAssertEqual(pb.string(forType: .string), "/a/b/c", "copy lands on the client pasteboard")
    }

    /// `.nothing` is a TRUE no-op: it never sends input, never fires a host callback, never touches the clipboard.
    func testNothingActionIsATrueNoOp() {
        let pb = ClientPasteboard.pasteboard
        pb.clearContents()
        pb.setString("sentinel", forType: .string)

        let model = TerminalViewModel()
        var sunk: [Data] = []
        var opened = 0
        var revealed = 0
        model.inputSink = { sunk.append($0) }
        model.onRequestOpenHostPath = { _ in opened += 1 }
        model.onRequestRevealHostPath = { _ in revealed += 1 }

        LinkActionActuator.actuate(.nothing, model: model)

        XCTAssertTrue(sunk.isEmpty, ".nothing sends no input")
        XCTAssertEqual(opened, 0, ".nothing fires no host-open")
        XCTAssertEqual(revealed, 0, ".nothing fires no host-reveal")
        XCTAssertEqual(pb.string(forType: .string), "sentinel", ".nothing leaves the pasteboard untouched")
    }

    /// A nil model makes an open/reveal/cd a silent no-op (a disconnected pane), never a crash.
    func testNoModelMakesHostActionsNoOpNeverCrash() {
        LinkActionActuator.actuate(.openHost("/x"), model: nil)
        LinkActionActuator.actuate(.revealHost("/x"), model: nil)
        LinkActionActuator.actuate(.changeDirectoryPTY("/x"), model: nil)
        // No assertion beyond "did not trap"; reaching here is the pass.
    }

    // MARK: - rowActions(for:store:model:)

    /// A URL row offers ONLY Open Link + Copy URL — no Reveal / Change-Directory (and no dropped SSH row): the
    /// `TerminalContextMenu.linkItems(for: .url)` routing is preserved verbatim by the extraction.
    func testRowActionsForURLOffersOpenAndCopyOnly() {
        let item = JumpToItem(
            id: "link:url:https://example.com", kind: .url, title: "https://example.com",
            timestamp: nil, act: .link(urlLink()),
        )
        let actions = LinkActionActuator.rowActions(for: item, store: makeStore(), model: TerminalViewModel())

        XCTAssertEqual(actions.map(\.title), ["Open Link", "Copy URL"], "a URL offers only Open + Copy URL")
    }

    /// Running a URL row's "Copy URL" action writes the raw URL to the client pasteboard (full
    /// rowActions → `LinkActionPolicy` → `actuate` path).
    func testRowActionsURLCopyWritesPasteboard() {
        let pb = ClientPasteboard.pasteboard
        pb.clearContents()
        let item = JumpToItem(
            id: "link:url:https://example.com", kind: .url, title: "https://example.com",
            timestamp: nil, act: .link(urlLink()),
        )
        let actions = LinkActionActuator.rowActions(for: item, store: makeStore(), model: TerminalViewModel())
        actions[1].run() // "Copy URL"

        XCTAssertEqual(pb.string(forType: .string), "https://example.com", "Copy URL writes the raw URL")
    }

    /// A path row offers the FULL set in order: Open / Copy Path / Reveal in Finder / Change Directory Here.
    func testRowActionsForPathOffersFullSet() {
        let item = JumpToItem(
            id: "link:path:/a/b/file.txt", kind: .path, title: "/a/b/file.txt",
            timestamp: nil, act: .link(pathLink()),
        )
        let actions = LinkActionActuator.rowActions(for: item, store: makeStore(), model: TerminalViewModel())

        XCTAssertEqual(
            actions.map(\.title),
            ["Open", "Copy Path", "Reveal in Finder", "Change Directory Here"],
            "a path offers the full Open / Copy Path / Reveal / Change-Directory set",
        )
    }

    /// Running a path row's "Change Directory Here" action sends the verbatim cd-parent-if-file line — the same
    /// idiom the renderer / leaf emit — proving the popover path actuates identically post-extraction.
    func testRowActionsPathChangeDirectorySendsVerbatimCdParentForFile() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        model.inputSink = { sunk.append($0) }
        let item = JumpToItem(
            id: "link:path:/a/b/file.txt", kind: .path, title: "/a/b/file.txt",
            timestamp: nil, act: .link(pathLink()),
        )
        let actions = LinkActionActuator.rowActions(for: item, store: makeStore(), model: model)
        actions[3].run() // "Change Directory Here"

        XCTAssertEqual(
            sunk,
            [Data("cd '/a/b/file.txt' 2>/dev/null || cd '/a/b'\n".utf8)],
            "Change Directory Here cd's to the file's parent, verbatim",
        )
    }

    /// A command BLOCK row offers Jump-to + Copy; running Copy writes the command text to the pasteboard.
    func testRowActionsForBlockOffersJumpAndCopy() {
        let pb = ClientPasteboard.pasteboard
        pb.clearContents()
        let item = JumpToItem(
            id: "block:3", kind: .command, title: "make build", timestamp: nil, act: .block(index: 3),
        )
        let actions = LinkActionActuator.rowActions(for: item, store: makeStore(), model: TerminalViewModel())

        XCTAssertEqual(actions.map(\.title), ["Jump to", "Copy"], "a command block offers Jump-to + Copy")
        actions[1].run() // "Copy"
        XCTAssertEqual(pb.string(forType: .string), "make build", "Copy writes the command text")
    }
}
#endif
