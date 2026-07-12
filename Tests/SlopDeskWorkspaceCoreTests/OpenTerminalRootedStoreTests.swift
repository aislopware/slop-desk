import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The terminal-rooted external-drop STORE ingress (`WorkspaceStore.openTerminalRooted`,
/// `WorkspaceStore+Drop.swift`): a dropped folder/file lands in a fresh terminal tab or split and the
/// `cd … || cd <parent>` line is sent VERBATIM through the new pane's session handle. (These tests lived in
/// the since-deleted `WebPaneStoreTests` — the local web pane is removed, but the terminal drop ingress is
/// core and stays pinned here.)
@MainActor
final class OpenTerminalRootedStoreTests: XCTestCase {
    /// A live tree-model store whose sessions are headless fakes (no socket) — the same seam
    /// `WorkspaceStoreProgressTests` / `DockTintPolicyTests` use.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    /// Drains the deferred (0 ms-grace) drop `cd` send by yielding the main actor until `fake` records bytes
    /// or the budget runs out (mirrors `CwdInheritanceStoreTests.waitForBytes`).
    private func waitForBytes(_ fake: FakePaneSession?) async {
        for _ in 0..<200 {
            if (fake?.sentBytes.count ?? 0) > 0 { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A dropped folder on the New-Tab zone (`DropAction.newTabCd`) opens a fresh
    /// TERMINAL tab and `cd`s it to the dropped path — falling back to the path's PARENT (a dropped FILE →
    /// its containing folder) via ``LinkActionPolicy/changeDirectoryCommandLine(_:)`` — sent VERBATIM through
    /// the new pane's `FakePaneSession` sink, NEVER `SendKeysParser`. `home` new-tab policy ⇒ the new tab
    /// inherits NO cwd, so the drop `cd` is the ONLY thing the fresh terminal sees and the exact line can be
    /// pinned. Revert-to-confirm-fail: on the un-fixed store `openTerminalRooted` does not exist (the test
    /// fails to compile); a `SendKeysParser` path would also yield different bytes.
    func testOpenTerminalRootedNewTabSendsParentFallbackCd() async throws {
        SettingsKey.store.set("home", forKey: SettingsKey.workingDirectoryNewTabKey)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.workingDirectoryNewTabKey) }

        let store = makeStore()
        let before = Set(store.tree.allPaneIDs())

        store.openTerminalRooted(at: "/Users/me/project", split: false, leading: false, launchGrace: .zero)

        let new = try XCTUnwrap(
            store.tree.allPaneIDs().first { !before.contains($0) },
            "openTerminalRooted(.newTab) adds a leaf",
        )
        XCTAssertEqual(store.tree.spec(for: new)?.kind, .terminal, "the dropped folder opens a terminal")
        let fake = store.handle(for: new) as? FakePaneSession
        await waitForBytes(fake)

        XCTAssertEqual(
            fake?.sentBytes,
            [Array("cd '/Users/me/project' 2>/dev/null || cd '/Users/me'\n".utf8)],
            "the new tab cd's to the dropped path, falling back to its parent — VERBATIM, not SendKeysParser",
        )
    }

    /// The split sibling (`DropAction.splitInjectPath`): the dropped path opens beside the active pane and the
    /// NEW split pane (only it) receives the `cd … || cd <parent>` line; the original terminal gets nothing.
    func testOpenTerminalRootedSplitSendsCdToTheNewPaneOnly() async throws {
        SettingsKey.store.set("home", forKey: SettingsKey.workingDirectoryNewSplitKey)
        defer { SettingsKey.store.removeObject(forKey: SettingsKey.workingDirectoryNewSplitKey) }

        let store = makeStore()
        let original = try XCTUnwrap(store.tree.allPaneIDs().first)
        let before = Set(store.tree.allPaneIDs())

        store.openTerminalRooted(at: "/srv/app/main.swift", split: true, leading: false, launchGrace: .zero)

        let new = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) }, "the split adds one leaf")
        let fake = store.handle(for: new) as? FakePaneSession
        await waitForBytes(fake)

        XCTAssertEqual(
            fake?.sentBytes,
            [Array("cd '/srv/app/main.swift' 2>/dev/null || cd '/srv/app'\n".utf8)],
            "the split pane cd's to the dropped path (file → parent fallback)",
        )
        XCTAssertEqual(
            (store.handle(for: original) as? FakePaneSession)?.sentBytes ?? [], [],
            "the original terminal receives nothing — the drop `cd` targets only the new pane",
        )
    }

    /// The Open-Quickly Folder "Split Down" action passes `axis: .vertical` to
    /// `openTerminalRooted`, which must split the active pane VERTICALLY (a stacked split), not horizontally.
    /// Revert-to-confirm-fail: on the un-fixed store `openTerminalRooted` has NO `axis` parameter (the call
    /// fails to compile) and always split `.horizontal`.
    func testOpenTerminalRootedSplitDownIsAVerticalSplit() throws {
        let store = makeStore()
        store.openTerminalRooted(at: "/srv/app", split: true, leading: false, axis: .vertical, launchGrace: .zero)

        let root = try XCTUnwrap(store.tree.activeSession?.activeTab?.root, "the active tab has a root")
        guard case let .split(_, axis, children) = root else {
            XCTFail("Split Down produces a split node at the tab root, not a bare leaf")
            return
        }
        XCTAssertEqual(axis, .vertical, "Split Down splits the active pane vertically (axis: .vertical)")
        XCTAssertEqual(children.count, 2, "the split has the original pane + the new folder terminal")
    }
}
