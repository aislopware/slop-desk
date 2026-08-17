// The headless store double this suite drives the shell's decisions over.
//
// SwiftPM gives a file to exactly ONE target, so a double cannot be shared across test targets the way
// production code is — `FakePaneSession` (WorkspaceCore's suite) and `MountTestPaneSession` (the UI suite)
// are the same shape for the same reason. This is the macOS shell's copy: the smallest
// `PaneSessionHandle` that lets a tree-model ``WorkspaceStore`` materialize without opening a socket or
// touching video, so a ⌘W can be observed as a leaf-count drop rather than mocked.

#if os(macOS)
import SlopDeskWorkspaceModel

// `@testable` for `PaneSessionIDAdopting` — the reconcile invariant's internal adoption seam, which every
// store double has to honour.
@testable import SlopDeskWorkspaceCore

@MainActor
final class MountTestPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false

    init(_ spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    // Sync witnesses legally satisfy the `async` protocol requirements (same as the canonical
    // `FakePaneSession`) and avoid the `async_without_await` strict-lint rule on the empty fake bodies.
    func pause() {}
    func resume() {}
    func teardown() {}
}
#endif
