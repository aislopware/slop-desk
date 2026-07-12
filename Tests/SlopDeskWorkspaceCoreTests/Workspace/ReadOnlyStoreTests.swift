import XCTest
@testable import SlopDeskWorkspaceCore

/// The per-pane READ-ONLY store seams (``WorkspaceStore/setPaneReadOnly(_:_:)`` /
/// ``WorkspaceStore/toggleReadOnlyInActivePane()`` / ``WorkspaceStore/isReadOnly(for:)``) and their
/// CONVERGENCE onto the single ``WorkspaceStore/paneReadOnly`` source of truth the pill `×`, the View menu,
/// and the command-palette term all funnel to.
///
/// Driven over ``RecordingTerminalPaneSession`` — a headless double carrying a REAL ``TerminalViewModel``,
/// so the store↔model drive (set ⇒ ``TerminalViewModel/isReadOnly`` gate) is exercised end-to-end WITHOUT a
/// socket or renderer (the hang-safety rule holds) — and ``FakePaneSession`` (no terminal model) so the
/// set-only path (a non-terminal / headless pane) is covered too.
@MainActor
final class ReadOnlyStoreTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store whose panes carry a REAL terminal model (so `setPaneReadOnly` drives a gate).
    private func makeRecordingStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
    }

    /// A `.tree`-live store backed by `FakePaneSession` (no terminal model) — the set-only convergence path.
    private func makeFakeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { FakePaneSession($0) }, liveVideoCap: 2,
        )
    }

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The live terminal model behind pane `id` on a recording-backed store.
    private func model(_ store: WorkspaceStore, _ id: PaneID) -> TerminalViewModel? {
        (store.handle(for: id) as? RecordingTerminalPaneSession)?.terminalModel
    }

    // MARK: - setPaneReadOnly drives BOTH the live model and the convergent set

    /// `setPaneReadOnly(id, true/false)` flips the pane's live ``TerminalViewModel/isReadOnly`` input gate
    /// (and its observable `readOnlyBadgeActive` pill mirror) AND records / clears the id in the convergent
    /// `paneReadOnly` set. Fails before the seam exists (won't compile) or if it touched only one of the two.
    func testSetPaneReadOnlyDrivesTheLiveModelAndTheSet() throws {
        let store = makeRecordingStore()
        let active = try XCTUnwrap(activePane(store))
        let m = try XCTUnwrap(model(store, active))
        XCTAssertFalse(m.isReadOnly)
        XCTAssertFalse(store.isReadOnly(for: active))

        store.setPaneReadOnly(active, true)
        XCTAssertTrue(m.isReadOnly, "the store drove the live model's input gate ON")
        XCTAssertTrue(m.readOnlyBadgeActive, "and the observable pill mirror lit")
        XCTAssertTrue(store.paneReadOnly.contains(active), "and recorded it in the convergent set")
        XCTAssertTrue(store.isReadOnly(for: active), "isReadOnly(for:) reads the convergent set")

        store.setPaneReadOnly(active, false)
        XCTAssertFalse(m.isReadOnly, "clearing drove the model gate OFF")
        XCTAssertFalse(m.readOnlyBadgeActive, "and cleared the pill mirror")
        XCTAssertFalse(store.paneReadOnly.contains(active), "and cleared the set")
    }

    // MARK: - The pill ×, the menu, and the palette converge to one state

    /// The three entry points converge on ONE state: the palette/menu (`toggleReadOnlyInActivePane`) locks
    /// the active pane, the pill `×` (`setPaneReadOnly(id, false)`) unlocks it, and a re-toggle re-locks —
    /// all observed through the single `paneReadOnly` set + the live model. Fails before the seams converge
    /// (e.g. if the toggle and the explicit set wrote different sources).
    func testToggleAndPillCrossConvergeOnOneState() throws {
        let store = makeRecordingStore()
        let active = try XCTUnwrap(activePane(store))
        let m = try XCTUnwrap(model(store, active))

        store.toggleReadOnlyInActivePane() // palette / View-menu entry
        XCTAssertTrue(store.isReadOnly(for: active), "the palette/menu toggle locked the active pane")
        XCTAssertTrue(m.isReadOnly, "and drove the live gate")

        store.setPaneReadOnly(active, false) // the pill × entry
        XCTAssertFalse(store.isReadOnly(for: active), "the pill × converges with the palette toggle")
        XCTAssertFalse(m.isReadOnly, "and released the live gate")

        store.toggleReadOnlyInActivePane() // back on
        XCTAssertTrue(store.isReadOnly(for: active))
        store.toggleReadOnlyInActivePane() // and off again
        XCTAssertFalse(store.isReadOnly(for: active), "the toggle is its own inverse")
    }

    // MARK: - Read-only is strictly per-pane (splitting yields a fresh editable pane)

    /// Locking one pane leaves its sibling writable — both in the convergent set AND in each live model
    /// (splitting always yields a fresh editable pane; the read-only state does not propagate to it).
    func testReadOnlyIsPerPane() throws {
        let store = makeRecordingStore()
        let a = try XCTUnwrap(activePane(store))
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let b = try XCTUnwrap(activePane(store))
        XCTAssertNotEqual(a, b)

        store.setPaneReadOnly(a, true)
        XCTAssertTrue(store.isReadOnly(for: a), "pane a is locked")
        XCTAssertFalse(store.isReadOnly(for: b), "its sibling b stays writable (per-pane)")
        let mb = try XCTUnwrap(model(store, b))
        XCTAssertFalse(mb.isReadOnly, "and the sibling's live gate stays open")
    }

    // MARK: - The set tracks read-only even for a pane with no live model (fake / non-terminal)

    /// On a `FakePaneSession`-backed store (no ``TerminalModelProviding`` ⇒ no live model),
    /// `toggleReadOnlyInActivePane` still records the state in the convergent set — so the pill / sidebar
    /// lock have a truth to read even before (or without) a live model echoes a value.
    func testToggleTracksTheSetWithoutALiveModel() throws {
        let store = makeFakeStore()
        let active = try XCTUnwrap(activePane(store))
        XCTAssertNil(model(store, active), "the fake handle carries no terminal model")

        store.toggleReadOnlyInActivePane()
        XCTAssertTrue(store.isReadOnly(for: active), "the set tracks read-only even with no live model")
        store.toggleReadOnlyInActivePane()
        XCTAssertFalse(store.isReadOnly(for: active), "and the toggle still inverts it")
    }

    // MARK: - A closed pane's read-only entry is pruned (no leak / stale lock)

    /// Closing a read-only pane drops its `paneReadOnly` entry on the reconcile prune (no unbounded growth,
    /// no stale lock on a recycled id); the surviving pane keeps its lock. Fails before the prune is wired.
    func testClosingAPanePrunesItsReadOnlyEntry() async throws {
        let store = makeRecordingStore()
        let a = try XCTUnwrap(activePane(store))
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let b = try XCTUnwrap(activePane(store))
        store.setPaneReadOnly(a, true)
        store.setPaneReadOnly(b, true)
        XCTAssertEqual(store.paneReadOnly, [a, b], "both panes are locked")

        store.focusPaneTree(b)
        store.requestCloseActivePaneTree() // close b
        await store.quiesce()

        XCTAssertFalse(store.paneReadOnly.contains(b), "the closed pane's read-only entry is pruned")
        XCTAssertTrue(store.paneReadOnly.contains(a), "the survivor keeps its lock")
    }

    // MARK: - Read-only DRIVES the `.remoteGUI` video-input gate (the load-bearing one)

    #if canImport(SwiftUI)
    /// **The read-only INPUT gate on the video seam.** A `.remoteGUI` pane has no live terminal
    /// model, so `setPaneReadOnly` lands purely in the convergent ``WorkspaceStore/paneReadOnly`` set (the
    /// set-only path). The pure ``RemotePaneContext/videoLeaf(isActive:readOnly:...)`` derivation `GuiLeafView`
    /// uses maps that policy onto the app-target client's gate: `inputEnabled == !readOnly`. So a locked remote
    /// window forwards NEITHER pointer/scroll NOR keycodes (wire-compatible silence). Fails on un-fixed code:
    /// `RemotePaneContext.inputEnabled` / `.videoLeaf` did not exist, so a "read-only" remote window still
    /// accepted input.
    func testReadOnlyDerivesTheVideoInputGate() {
        let store = makeFakeStore()
        let video = store.newRemoteWindowTab(windowID: 7, title: "Safari", appName: "Safari")

        // WRITABLE: the seam derivation enables input forwarding.
        let writable = RemotePaneContext.videoLeaf(
            isActive: true, readOnly: store.isReadOnly(for: video), bindKeyInjector: { _ in },
        )
        XCTAssertTrue(writable.inputEnabled, "a writable `.remoteGUI` pane forwards pointer/scroll/keycodes")

        // LOCK (set-only path — a video pane carries no live `TerminalViewModel`).
        store.setPaneReadOnly(video, true)
        XCTAssertTrue(store.isReadOnly(for: video), "read-only records the `.remoteGUI` pane in the convergent set")

        // READ-ONLY: the SAME derivation now disables the input gate.
        let locked = RemotePaneContext.videoLeaf(
            isActive: true, readOnly: store.isReadOnly(for: video), bindKeyInjector: { _ in },
        )
        XCTAssertFalse(locked.inputEnabled, "a read-only `.remoteGUI` pane forwards NO input (the app-target gate)")
    }

    /// **Read-only CLEARS the paste-as-keystrokes sink at the seam (no model→store coupling).**
    /// The video view publishes a live key-injection sink through ``RemotePaneContext/onKeyInjectorReady``;
    /// the `.videoLeaf` derivation hands the model a `nil` sink instead while read-only, so the model's
    /// ``RemoteWindowModel/canPasteKeystrokes`` is `false` and ``RemoteWindowModel/pasteAsKeystrokes(_:)`` is
    /// inert — WITHOUT the model ever learning the read-only state. Fails on un-fixed code, where the context
    /// bound the published sink unconditionally (paste-as-keystrokes stayed live on a "read-only" pane).
    func testReadOnlyClearsThePasteKeystrokesSinkAtTheSeam() {
        let model = RemoteWindowModel(windowID: "7", title: "Safari")
        model.open() // active != nil ⇒ canPasteKeystrokes now hinges purely on whether a sink is bound
        XCTAssertNotNil(model.active, "the model is streaming, so only the sink gates paste-as-keystrokes")
        let liveSink: (UInt16, Bool, Bool) -> Void = { _, _, _ in }

        // WRITABLE: the seam binds the published sink → paste-as-keystrokes is possible.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: false, bindKeyInjector: { model.keyInjector = $0 },
        ).onKeyInjectorReady?(liveSink)
        XCTAssertNotNil(model.keyInjector, "writable: the published sink reaches the model")
        XCTAssertTrue(model.canPasteKeystrokes, "writable: paste-as-keystrokes is enabled")

        // READ-ONLY: the seam withholds the sink (binds nil) EVEN THOUGH the view publishes a real one.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { model.keyInjector = $0 },
        ).onKeyInjectorReady?(liveSink)
        XCTAssertNil(model.keyInjector, "read-only: the seam clears the model's key-injection sink")
        XCTAssertFalse(model.canPasteKeystrokes, "read-only: paste-as-keystrokes is inert")
    }

    /// **Read-only WITHHOLDS the Release-Stuck-Input sink at the seam.** The escape hatch sends
    /// host input (synthetic key/mouse releases), so — exactly like the paste-as-keystrokes sink — the
    /// `.videoLeaf` derivation binds `nil` while read-only: the palette row is inert on a locked pane
    /// (`canReleaseStuckInput == false`) without the model ever learning the read-only state.
    func testReadOnlyWithholdsTheInputReleaseSinkAtTheSeam() {
        let model = RemoteWindowModel(windowID: "7", title: "Safari")
        model.open()
        let liveSink: () -> Void = {}

        // WRITABLE: the seam binds the published release sink → the escape hatch is armed.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: false, bindKeyInjector: { _ in },
            bindInputRelease: { model.inputReleaseInjector = $0 },
        ).onInputReleaseReady?(liveSink)
        XCTAssertNotNil(model.inputReleaseInjector, "writable: the published release sink reaches the model")
        XCTAssertTrue(model.canReleaseStuckInput, "writable: the palette escape hatch is live")

        // READ-ONLY: the seam withholds the sink (binds nil) EVEN THOUGH the view publishes a real one.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
            bindInputRelease: { model.inputReleaseInjector = $0 },
        ).onInputReleaseReady?(liveSink)
        XCTAssertNil(model.inputReleaseInjector, "read-only: the seam clears the release sink")
        XCTAssertFalse(model.canReleaseStuckInput, "read-only: a locked pane cannot inject releases")
    }
    #endif
}
