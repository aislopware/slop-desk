import AislopdeskTerminal
import Foundation
@testable import AislopdeskWorkspaceCore

// MARK: - RecordingSurfaceActions (a headless TerminalSurface that records performBindingAction)

/// A headless ``TerminalSurface`` that ALSO conforms to ``TerminalSurfaceActions`` and RECORDS every
/// `performBindingAction` string in call order — so a store-level test can observe the libghostty actions
/// the WB2/WB3 jump glue emits (`scroll_to_bottom`, `jump_to_prompt:<delta>`) WITHOUT a real GhosttySurface
/// (which hangs without a window server — the hang-safety rule). It never touches VideoToolbox / Metal /
/// SCStream / a real terminal; it is a pure in-memory recorder.
///
/// NON-isolated (like ``HeadlessTerminalSurface``) so it satisfies the nonisolated `TerminalSurface` /
/// `TerminalSurfaceActions` protocols; an `NSLock` guards the recorded actions (`@unchecked Sendable`),
/// though the tests only touch it from the main actor.
final class RecordingSurfaceActions: TerminalSurface, TerminalSurfaceActions, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var onWrite: ((Data) -> Void)?

    /// Drives ``readSelection``/``hasSelection`` so a copy-mode test can stage a mouse-made selection
    /// (non-nil = a selection exists). Default `nil` = no selection (the WB2/WB3 jump tests want that).
    var selectionText: String?

    /// Drives ``scrollbackTextLines`` so the no-selection copy fallback has something to return.
    var scrollbackLines: [String] = []

    private var scrollbackCalls = 0

    /// How many times ``scrollbackTextLines`` was called — the assertion surface for the E5 perf fix
    /// (the cross-seam scrollback mirror must be gathered ONCE per overlay-open, not once per keystroke).
    var scrollbackTextLinesCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scrollbackCalls
    }

    /// Every `performBindingAction` argument, in call order — the assertion surface for jump routing.
    var actions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Clears the recorded actions (so a test can assert a SECOND route's actions in isolation).
    func resetActions() {
        lock.lock()
        defer { lock.unlock() }
        recorded.removeAll()
    }

    // TerminalSurface (inert — the block ops never feed bytes through here).
    func feed(_: Data) {}
    func setSize(cols _: UInt16, rows _: UInt16) {}
    func handleInput(_: Data) {}

    // TerminalSurfaceActions: the menu/find/jump lever. We record the action and report success.
    func hasSelection() -> Bool { selectionText != nil }
    func readSelection() -> String? { selectionText }
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        lock.lock()
        recorded.append(action)
        lock.unlock()
        return true
    }

    func scrollbackTextLines() -> [String] {
        lock.lock()
        scrollbackCalls += 1
        lock.unlock()
        return scrollbackLines
    }
}

// MARK: - RecordingTerminalPaneSession (a LivePaneSession-shaped recording double)

/// A ``PaneSessionHandle`` test double that — unlike ``FakePaneSession`` — carries a REAL
/// ``TerminalViewModel`` (so it conforms to the store's ``TerminalModelProviding`` seam), letting the WB2 /
/// WB3 block-routing glue (navigator / jump-to-block / re-run-last / jump-to-failed / bookmark seed) be
/// exercised end-to-end WITHOUT a socket or a real renderer. The model's `sendInput` is wired to record the
/// re-run bytes; its `surface` is a ``RecordingSurfaceActions`` recording the jump actions.
///
/// Built from a ``PaneSpec`` exactly like ``LivePaneSession.make`` / ``FakePaneSession`` so it drops into
/// the store's `makeSession` seam. A `.terminal` spec gets a live model; any other kind has `nil`
/// `terminalModel` (mirroring `LivePaneSession`'s `.remoteGUI` → no terminal).
@MainActor
@Observable
final class RecordingTerminalPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable,
    PaneSessionIDAdopting, TerminalModelProviding, ComposerProviding
{
    private(set) var id: PaneID
    let kind: PaneKind

    /// The real per-pane terminal model for a `.terminal` pane; `nil` otherwise (matches `LivePaneSession`).
    let terminalModel: TerminalViewModel?

    /// E12: the real per-pane Composer for a `.terminal` pane; `nil` otherwise (matches `LivePaneSession`).
    /// So the E12 active-pane composer routing (`requestComposerInActivePane` / `requestPromptQueueInActivePane`)
    /// is exercisable end-to-end through the `ComposerProviding` seam without a socket.
    let composer: ComposerModel?

    /// `ComposerProviding`: the composer the store's active-pane composer ops resolve.
    var composerModel: ComposerModel? { composer }

    /// The recording surface backing `terminalModel` (so a test reads `surfaceRecorder.actions`).
    let surfaceRecorder: RecordingSurfaceActions?

    /// A fresh per-materialization bookmark scope key (mirrors `LivePaneSession.bookmarkScopeKey`).
    let bookmarkScopeKey = UUID().uuidString

    /// Every byte payload routed through the model's `sendInput` (the re-run path), in call order.
    private(set) var sentInput: [Data] = []

    init(_ spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
        if spec.kind == .terminal {
            let recorder = RecordingSurfaceActions()
            let model = TerminalViewModel(surface: recorder)
            surfaceRecorder = recorder
            terminalModel = model
            // E12: a real per-pane composer whose OUT sink also funnels through the recorded input path, so a
            // routing/idle-dispatch test can observe both the composer state AND the bytes it emits.
            let box = ComposerModel()
            composer = box
            // Only NOW may the OUT-path closures capture `self`: definite-initialization requires every
            // stored `let` (incl. `composer`) assigned before a `[weak self]` capture forms a reference.
            // Wire the OUT path so `sendInput` is observable (production wires this on connect).
            model.inputSink = { [weak self] data in self?.sentInput.append(data) }
            box.send = { [weak self] data in self?.sentInput.append(data) }
        } else {
            surfaceRecorder = nil
            terminalModel = nil
            composer = nil
        }
    }

    func adopt(id: PaneID) { self.id = id }

    // PaneSessionHandle — inert lifecycle (the block routing never drives these). The `await Task.yield()`
    // satisfies the protocol's `async` signature without real work (and the async_without_await lint rule).
    var isVideoActive: Bool { false }
    func setVideoActive(_: Bool) {}
    func pause() async { await Task.yield() }
    func resume() async { await Task.yield() }
    func teardown() async { await Task.yield() }
}
