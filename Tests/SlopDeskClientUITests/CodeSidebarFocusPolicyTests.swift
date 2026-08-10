#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI

/// ``CodeSidebarFocusPolicy`` — the embedded VS Code may take the keyboard ONLY from a direct user
/// mouse-down inside the webview; every autofocus path is refused. Pure truth-table (hang-safety:
/// no WKWebView is ever constructed here — the policy is the whole decision).
final class CodeSidebarFocusPolicyTests: XCTestCase {
    func testUserClickInsideIsHonored() {
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .leftMouseDown, clickWasInsideWebView: true),
        )
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .rightMouseDown, clickWasInsideWebView: true),
        )
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .otherMouseDown, clickWasInsideWebView: true),
        )
    }

    func testClickOutsideIsRefused() {
        // A mouse-down elsewhere in the window with a coincident page `focus()` must not move the
        // keyboard into the editor.
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .leftMouseDown, clickWasInsideWebView: false),
        )
    }

    func testProgrammaticAutofocusIsRefused() {
        // VS Code's own `focus()` (load, file open, layout change) arrives with NO current event.
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: nil, clickWasInsideWebView: true),
        )
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: nil, clickWasInsideWebView: false),
        )
    }

    func testAutofocusRidingAnUnrelatedEventIsRefused() {
        // An autofocus can land while ANY event is current — a keystroke bound for the terminal, a
        // scroll, a hover. None of them is consent, wherever the pointer happens to sit.
        for type: NSEvent.EventType in [.keyDown, .keyUp, .scrollWheel, .mouseMoved, .leftMouseUp, .flagsChanged] {
            XCTAssertFalse(
                CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: type, clickWasInsideWebView: true),
                "\(type) must not hand the webview the keyboard",
            )
        }
    }

    // MARK: Reserved app chords

    func testAppManagementChordsAreReserved() {
        // Quit / Hide / Hide Others / Minimize belong to the APP even while the editor holds the
        // keyboard — WKWebView's performKeyEquivalent would otherwise feed them to the page before
        // the main menu ever sees them.
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "q"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "h"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command, .option], key: "h"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "m"))
    }

    /// ⌘` is deliberately NOT reserved here any more: the NSEvent monitor claims it ahead of this
    /// seam and hands the keyboard back to the terminal pane instead of cycling windows
    /// (`DispatcherCodeSidebarYieldTests`). Listing it would be a rule that never runs.
    func testWindowCyclingIsNoLongerClaimedAtThisSeam() {
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "`"))
    }

    func testDeviceDependentFlagBitsDoNotDefeatTheMatch() {
        // Real events carry device-dependent bits (left/right key distinction, caps state) on top
        // of `.command` — the policy must match on the chord, not raw-value equality.
        let raw = NSEvent.ModifierFlags([.command, .init(rawValue: 0x108)])
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: raw, key: "q"))
    }

    func testEditorChordsStayWithTheWorkbench() {
        // The user focused the editor on purpose: its own keymap keeps everything else.
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "w"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "p"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: ","))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command, .shift], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.option], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: nil))
    }

    // MARK: Editing chords

    func testBareCommandEditingChordsMapToTheNativeEditingActions() {
        // VS Code web never acts on raw ⌘C/⌘V/⌘X keydowns — it registers those three commands with
        // their keybinding gated on the native build, because in a browser they are the Edit
        // menu's, and this app's menus are shortcut-less. The webview claims them and drives
        // WebKit's own editing actions instead; unclaimed they bounce back and became phantom
        // terminal input (libghostty's cmd+v paste binding).
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "c"), .copy)
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "v"), .paste)
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "x"), .cut)
    }

    func testWorkbenchOwnedChordsAreNeverClaimedAsEditingCommands() {
        // The mirror of the pin above, and the reason it is narrow: ⌘A / ⌘Z / ⌘⇧Z carry an
        // unconditional core keybinding in the web build and route themselves to a native text
        // input when one has focus, so the page owns them everywhere. Claiming ⌘A ran WebKit's DOM
        // select-all against the editor's hidden scratch textarea, and select-all in the editor did
        // nothing (user-reported 2026-08-05). Anything added here outranks the workbench silently.
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "a"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "z"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .shift], key: "z"))
    }

    func testModifiedOrForeignChordsAreNotEditingCommands() {
        // Shifted/optioned variants and every other letter stay with VS Code's own keymap
        // (⌘⇧V markdown preview, ⌘⌥C toggle-case-sensitive find, …).
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .shift], key: "v"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .option], key: "c"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .control], key: "x"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "p"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [], key: "c"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: nil))
    }

    func testDeviceDependentFlagBitsDoNotDefeatTheEditingMatch() {
        let raw = NSEvent.ModifierFlags([.command, .init(rawValue: 0x108)])
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: raw, key: "v"), .paste)
    }

    // MARK: Keyboard ownership across key-window changes

    func testAppDeactivationPreservesOwnership() {
        // ⌘⇥ to another app: `didResignKey` fires with NO key window left. The keyboard left the
        // APP, not the editor — dropping the flag here is what let the terminal reclaim first
        // responder in the background, so ⌘⇥-ing back landed in the terminal instead of the editor.
        XCTAssertTrue(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: true, hasKeyWindow: false, webViewHoldsFirstResponder: false,
        ))
        // And a terminal-owned keyboard stays terminal-owned across the same round trip.
        XCTAssertFalse(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: false, hasKeyWindow: false, webViewHoldsFirstResponder: false,
        ))
    }

    func testIntraAppKeyWindowMoveRederivesFromTheLiveResponder() {
        // A satellite pane window taking key moves the keyboard WITHOUT any responder transition —
        // the webview stays its own window's first responder, but it no longer receives keys.
        XCTAssertFalse(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: true, hasKeyWindow: true, webViewHoldsFirstResponder: false,
        ))
        // The main window taking key back with the webview still first responder re-lights it.
        XCTAssertTrue(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: false, hasKeyWindow: true, webViewHoldsFirstResponder: true,
        ))
    }

    // MARK: Remount restore (warm-swap focus hand-back)

    func testRemountInTheClaimedTabRestores() {
        // The editor owned the keyboard in tab A; a tab round-trip (or the panel's Desktop tab /
        // a collapse) unmounted the webview. Remounting back in tab A hands the keyboard back —
        // the workbench looks exactly as it was left, so typing must land in it again.
        XCTAssertTrue(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: ["A": "/repo"], activeTab: "A", projectRoot: "/repo",
        ))
    }

    func testRemountInAnotherTabNeverSteals() {
        // Another tab's pane focusing into this project remounts the same pooled webview — the
        // user just focused THAT pane; the editor must not yank the keyboard from it.
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: ["A": "/repo"], activeTab: "B", projectRoot: "/repo",
        ))
    }

    func testRemountOfAnotherProjectInAPanelTabNeverSteals() {
        // The tab reads the panel, but this is not the workbench it was reading — a project swap
        // mid-flight must not land the keyboard in a workbench the user never focused.
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: ["A": "/repo"], activeTab: "A", projectRoot: "/other",
        ))
    }

    // MARK: Per-tab focus region

    func testAGestureResignForgetsOnlyTheTabItHappenedIn() {
        // The user clicked tab B's terminal: B reads its terminal again, and A — which the user left
        // mid-edit — stays a panel tab. Forgetting A here is the bug this map replaced.
        let memory = CodeSidebarFocusPolicy.memoryAfterResign(
            ["A": "/repo", "B": "/repo"], resigningTab: "B", stillInWindow: true,
        )
        XCTAssertEqual(memory, ["A": "/repo"])
    }

    func testAnUnmountResignForgetsNothing() {
        // A warm swap took the keyboard, not the user — the tab is still a panel tab and its remount
        // hands the keyboard back.
        let memory = CodeSidebarFocusPolicy.memoryAfterResign(
            ["A": "/repo"], resigningTab: "A", stillInWindow: false,
        )
        XCTAssertEqual(memory, ["A": "/repo"])
    }

    func testSwitchingIntoAPanelTabClaimsTheEditor() {
        XCTAssertEqual(
            CodeSidebarFocusPolicy.tabSwitchFocus(
                incoming: "A", memory: ["A": "/repo"], editorHoldsKeyboard: false,
            ),
            .claimEditor(projectRoot: "/repo"),
        )
    }

    func testSwitchingIntoATerminalTabTakesTheKeyboardBack() {
        // The panel does not travel between tabs: a tab that was never edited in reads its terminal.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.tabSwitchFocus(
                incoming: "B", memory: ["A": "/repo"], editorHoldsKeyboard: true,
            ),
            .yieldToWorkspace,
        )
    }

    func testAlreadyCorrectSwitchesMoveNothing() {
        // Terminal tab, keyboard already in the workspace — and a panel tab arriving while the editor
        // holds the keyboard, where the column's own remount is what re-points it.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.tabSwitchFocus(
                incoming: "B", memory: [:], editorHoldsKeyboard: false,
            ),
            .leaveAlone,
        )
        XCTAssertEqual(
            CodeSidebarFocusPolicy.tabSwitchFocus(
                incoming: "A", memory: ["A": "/repo"], editorHoldsKeyboard: true,
            ),
            .leaveAlone,
        )
    }

    func testAnUnwiredActiveTabDecidesNothing() {
        // Headless / pre-wiring: no tab means no region to honour, and no memory to forget.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.tabSwitchFocus(
                incoming: String?.none, memory: ["A": "/repo"], editorHoldsKeyboard: false,
            ),
            .leaveAlone,
        )
        XCTAssertEqual(
            CodeSidebarFocusPolicy.memoryAfterResign(
                ["A": "/repo"], resigningTab: String?.none, stillInWindow: true,
            ),
            ["A": "/repo"],
        )
    }

    // MARK: Orphan-repair owner tracking

    func testOnlyAForeignViewQualifiesAsTheKeyboardOwner() {
        // The terminal (any view outside the pool) is worth remembering as the repair target.
        XCTAssertTrue(CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: true, responderIsWindow: false, responderInsidePooledWebView: false,
        ))
        // The window as its own first responder IS the orphaned state — never a repair target.
        XCTAssertFalse(CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: false, responderIsWindow: true, responderInsidePooledWebView: false,
        ))
        // A pooled webview (or its WebKit internals) must never be remembered: the repair would
        // hand the keyboard to the thief the policy just refused.
        XCTAssertFalse(CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: true, responderIsWindow: false, responderInsidePooledWebView: true,
        ))
        // A non-view responder (field editor delegate chains, nil) has no window to return to.
        XCTAssertFalse(CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: false, responderIsWindow: false, responderInsidePooledWebView: false,
        ))
    }

    // MARK: - ⌥⌘R: the keyboard's way in and out

    func testFocusToggleHandsBackWhenTheEditorHasTheKeyboard() {
        // Direction is read from where first responder actually IS, never from a remembered
        // intent — the same chord has to work as "leave the editor" without a second binding.
        for collapsed in [true, false] {
            for mounted in [true, false] {
                XCTAssertEqual(
                    CodeSidebarFocusPolicy.focusToggle(
                        webViewHoldsKeyboard: true, hasMountedWebView: mounted, panelCollapsed: collapsed,
                    ),
                    .handBack,
                )
            }
        }
    }

    func testFocusToggleClaimsTheMountedEditor() {
        XCTAssertEqual(
            CodeSidebarFocusPolicy.focusToggle(
                webViewHoldsKeyboard: false, hasMountedWebView: true, panelCollapsed: false,
            ),
            .claimEditor,
        )
    }

    func testFocusToggleRevealsAHiddenPanelFirst() {
        // Collapsed means the webview is unparented, so there is nothing to claim YET — the reveal
        // has to come first and the claim has to wait for the mount it triggers.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.focusToggle(
                webViewHoldsKeyboard: false, hasMountedWebView: false, panelCollapsed: true,
            ),
            .revealThenClaim,
        )
        XCTAssertEqual(
            CodeSidebarFocusPolicy.focusToggle(
                webViewHoldsKeyboard: false, hasMountedWebView: true, panelCollapsed: true,
            ),
            .revealThenClaim,
        )
    }

    func testFocusToggleDoesNothingWithNoWorkbenchOnScreen() {
        // The panel is open but showing a placeholder (no project in focus, code-server still
        // starting, no binary on the host). Moving the keyboard to nothing would be worse than
        // leaving it where the user can still type.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.focusToggle(
                webViewHoldsKeyboard: false, hasMountedWebView: false, panelCollapsed: false,
            ),
            CodeSidebarFocusPolicy.FocusToggleOutcome.none,
        )
    }

    // MARK: - Warm-pool eviction

    func testNothingIsEvictedAtOrUnderTheCap() {
        // The pool's whole value is warmth; it may only give it up once it is over the line.
        XCTAssertNil(CodeSidebarFocusPolicy.evictionVictim(recency: [], protected: [], cap: 3))
        XCTAssertNil(CodeSidebarFocusPolicy.evictionVictim(recency: ["a", "b", "c"], protected: [], cap: 3))
    }

    func testTheColdestProjectIsEvictedFirst() {
        XCTAssertEqual(
            CodeSidebarFocusPolicy.evictionVictim(recency: ["a", "b", "c", "d"], protected: [], cap: 3),
            "a",
        )
    }

    func testProtectedProjectsAreSkipped() {
        // The mounted workbench and any project still owed a keyboard hand-back are protected;
        // eviction walks past them to the next-coldest rather than giving up.
        XCTAssertEqual(
            CodeSidebarFocusPolicy.evictionVictim(recency: ["a", "b", "c", "d"], protected: ["a"], cap: 3),
            "b",
        )
        XCTAssertEqual(
            CodeSidebarFocusPolicy.evictionVictim(
                recency: ["a", "b", "c", "d"], protected: ["a", "b"], cap: 3,
            ),
            "c",
        )
    }

    func testAnAllProtectedPoolEvictsNothing() {
        // Over the cap but nothing may go: the pool stays oversized rather than blanking a live
        // view. It comes back under the cap on the next mount that frees one.
        XCTAssertNil(CodeSidebarFocusPolicy.evictionVictim(
            recency: ["a", "b", "c", "d"], protected: ["a", "b", "c", "d"], cap: 3,
        ))
    }

    func testUnclaimedOrUnwiredTabsNeverRestore() {
        // No tab ever claimed the keyboard, or the app never wired the active-tab provider (headless
        // tests): the restore must stay off rather than fire on a nil == nil coincidence.
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: [String: String](), activeTab: "A", projectRoot: "/repo",
        ))
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: [String: String](), activeTab: String?.none, projectRoot: "/repo",
        ))
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: ["A": "/repo"], activeTab: String?.none, projectRoot: "/repo",
        ))
    }
}
#endif
