// WorkspaceChromePinTests — pins the testable surface of "Pin Window" WITHOUT an NSWindow.
//
// The macOS window-level glue itself is hang-unsafe to exercise (CLAUDE.md rule #6 — never instantiate an
// NSWindow in a test), so the pin actuation (the native `.windowLevel(chrome.pinned ? .floating :
// .normal)` scene modifier) + `applyInitialWindowSize` are compiled-and-reviewed only; the pure window-sizing
// math is covered by `WindowSizeMathTests` and the action routing by
// `WorkspaceBindingRoutingTests`. What IS unit-testable here is the model contract the glue actuates:
// the `WorkspaceChromeState.pinned` flag + the `OverlayCoordinator.togglePinWindow` seam the root view
// (`wireChromeToggles`) and the menu (`WorkspaceCommands`) flip — driven headlessly, no AppKit.

import Defaults
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class WorkspaceChromePinTests: XCTestCase {
    /// The RIGHT code panel's collapse is the one PERSISTED chrome flag: a fresh
    /// `WorkspaceChromeState` (≙ a relaunch) seeds from `Defaults[.codeSidebarCollapsed]`, and both
    /// write paths (`toggleCodeSidebar` / `revealCodeSidebar`) store the choice back — the full
    /// remember-open/closed round-trip, headless. (Runs against the per-pid XCTest defaults suite,
    /// so nothing leaks into the developer's real prefs; still restored below for suite-mates.)
    func testCodeSidebarCollapseSeedsFromAndPersistsToDefaults() {
        let original = Defaults[.codeSidebarCollapsed]
        defer { Defaults[.codeSidebarCollapsed] = original }

        Defaults[.codeSidebarCollapsed] = false
        let chrome = WorkspaceChromeState()
        XCTAssertFalse(chrome.codeSidebarCollapsed, "a chrome born after an expanded session restores expanded")

        chrome.toggleCodeSidebar()
        XCTAssertTrue(chrome.codeSidebarCollapsed)
        XCTAssertTrue(Defaults[.codeSidebarCollapsed], "the manual hide persists")
        XCTAssertTrue(
            WorkspaceChromeState().codeSidebarCollapsed,
            "a relaunch (fresh chrome) reads the persisted hide",
        )

        chrome.toggleCodeSidebar()
        XCTAssertFalse(Defaults[.codeSidebarCollapsed], "the manual show persists too")

        chrome.toggleCodeSidebar() // hidden again…
        chrome.revealCodeSidebar() // …and the open-in-code reveal is the second write path
        XCTAssertFalse(Defaults[.codeSidebarCollapsed], "revealCodeSidebar persists the expand")
    }

    /// The code panel's OPEN GATE state: a chrome with nothing persisted has admitted NO project —
    /// the panel greets every root with the gate, never a booting workbench — and `openCodeProject`
    /// admits exactly the root it was given. PERSISTED (user-directed 2026-08-07, re-scoping the
    /// same-day session-scoped decision): a fresh `WorkspaceChromeState` (≙ a relaunch) seeds from
    /// `Defaults[.openedCodeProjects]`, so a project whose workbench was opened once comes back
    /// booting instead of re-gated — the startup path must not charge a click plus a cold boot
    /// for a surface the user already asked for. (Per-pid XCTest defaults suite; restored below.)
    func testOpenedCodeProjectsStartEmptyAndAdmitPerRootPersistently() {
        let original = Defaults[.openedCodeProjects]
        defer { Defaults[.openedCodeProjects] = original }
        Defaults[.openedCodeProjects] = []

        let chrome = WorkspaceChromeState()
        XCTAssertTrue(chrome.openedCodeProjects.isEmpty, "nothing persisted ⇒ no workbench admitted")

        chrome.openCodeProject("/Users/x/proj-a")
        XCTAssertTrue(chrome.openedCodeProjects.contains("/Users/x/proj-a"))
        XCTAssertFalse(
            chrome.openedCodeProjects.contains("/Users/x/proj-b"),
            "admitting one root never opens the gate for another",
        )

        chrome.openCodeProject("/Users/x/proj-a") // idempotent — a re-open is not an error
        XCTAssertEqual(chrome.openedCodeProjects.count, 1)

        XCTAssertEqual(
            WorkspaceChromeState().openedCodeProjects, ["/Users/x/proj-a"],
            "a relaunch (fresh chrome) restores the admitted set — an opened project is never re-gated",
        )
    }

    /// A fresh window is NOT pinned (pinning is an explicit affordance), and `togglePin()`
    /// flips the flag each call. REVERT-TO-CONFIRM-FAIL: the property / method do not exist on the un-fixed
    /// `WorkspaceChromeState`, so this fails to compile-then-pass only once the property / method are added.
    func testTogglePinFlipsTheChromeFlag() {
        let chrome = WorkspaceChromeState()
        XCTAssertFalse(chrome.pinned, "a fresh window resting state is UNpinned")

        chrome.togglePin()
        XCTAssertTrue(chrome.pinned, "togglePin() pins the window")

        chrome.togglePin()
        XCTAssertFalse(chrome.pinned, "a second togglePin() un-pins it")
    }

    /// The `OverlayCoordinator.togglePinWindow` seam — bound by `WorkspaceRootView.wireChromeToggles()` to
    /// `chrome.togglePin()` so the palette / any command surface flips the SAME live `chrome.pinned` the menu
    /// Button + the `NSWindow.level` glue read. Pins the wiring contract the app depends on. REVERT-TO-
    /// CONFIRM-FAIL: drop the `overlay.togglePinWindow = { chrome.togglePin() }` line from `wireChromeToggles`
    /// (the live binding) and the routed toggle no longer reaches the flag — `pinned` stays false.
    func testOverlayPinSeamFlipsTheChromeFlag() {
        let chrome = WorkspaceChromeState()
        let overlay = OverlayCoordinator()
        // Bind the seam exactly the way the root view does on appear.
        overlay.togglePinWindow = { chrome.togglePin() }

        overlay.togglePinWindow()
        XCTAssertTrue(chrome.pinned, "routing through the overlay pin seam flips the live chrome flag")
    }

    /// The default `togglePinWindow` seam (no root-view binding — tests / previews / a pre-`onAppear` scene)
    /// is a GRACEFUL no-op, never a trap: invoking it does nothing and does not crash.
    func testUnboundOverlayPinSeamIsAGracefulNoOp() {
        let overlay = OverlayCoordinator()
        overlay.togglePinWindow() // no binding ⇒ the default `{}` runs, no crash
    }

    /// The palette ✓ gutter tracks the pinned state. `OverlayHostView.toggledState(for:)`
    /// resolves the "action.pinWindow" row to `chrome.pinned`, so the palette lights the checkmark while
    /// pinned and clears it when unpinned — the checkable Pin Window row. REVERT-TO-CONFIRM-FAIL:
    /// drop the `case "action.pinWindow": chrome.pinned` arm and the resolver falls to the `default: false`,
    /// so the ✓ never lights and `pinned == true` below fails.
    func testToggledStateLightsPinRowWhenPinned() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        let chrome = WorkspaceChromeState()
        let pinItem = PaletteItem(
            id: "action.pinWindow", icon: "pin", title: "Pin Window",
            subtitle: nil, shortcut: nil, filter: .actions, category: .window, action: .togglePinWindow,
        )

        let unpinnedResolver = OverlayHostView.toggledState(for: chrome, store: store)
        XCTAssertFalse(unpinnedResolver(pinItem), "an unpinned window shows no ✓ on the Pin Window row")

        chrome.togglePin() // pin it
        let pinnedResolver = OverlayHostView.toggledState(for: chrome, store: store)
        XCTAssertTrue(pinnedResolver(pinItem), "a pinned window lights the ✓ on the Pin Window row")
    }
}
