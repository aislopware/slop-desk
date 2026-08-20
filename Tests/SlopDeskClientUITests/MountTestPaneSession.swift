// MountTestPaneSession — this suite's `PaneSessionHandle` double.
//
// Extracted from `OverlayCoordinatorMountTests` when docs/56's ClientUI→ClientCore test migration moved
// every OTHER user of this double (`OverlayCoordinatorMountTests` itself, `MovePaneToTabSourceTests`,
// `PaletteContentAndReachTests`, `RailRowBuilderTests`, `RailRowsMemoTests`, `WorkspaceChromePinTests`)
// down to `SlopDeskClientCoreTests`, where the equivalent double is `RecordingPaneSession`
// (`Tests/SlopDeskClientCoreTests/Support/RecordingPaneSession.swift`). `SharedFocusSettingTests` is the
// one file left in THIS target that still needs a tree-model `WorkspaceStore` fixture (it exercises
// `SettingsSheet`, a real ClientUI view), so the double stays here as its own file rather than living
// inside a test case that moved away.
//
// The tiniest `PaneSessionHandle` satisfying the store's `makeSession` seam without opening a socket or
// touching video — so a tree-model ``WorkspaceStore`` materializes for a suite's fixtures. The explicit
// `@MainActor` conformance markers on `PaneSessionHandle` / `Identifiable` are load-bearing: without them
// the `Identifiable.id` requirement is nonisolated while this `@MainActor` class's `id` getter is
// isolated, which Swift 6 strict concurrency flags as a data-race-crossing conformance
// (#ConformanceIsolation).

import SlopDeskWorkspaceModel
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
