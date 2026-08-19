// RecordingPaneSession — this suite's `PaneSessionHandle` double.
//
// One double for the whole target, the way `SlopDeskWorkspaceCoreTests` keeps `FakePaneSession`: it
// satisfies the store's `makeSession` seam without opening a socket or touching video, so a
// tree-model `WorkspaceStore` materializes headlessly (CLAUDE.md rule #6 — no socket, no GUI, no
// SCStream/VT/Metal/NSWindow).
//
// The explicit `@MainActor` conformance markers on `PaneSessionHandle` / `Identifiable` are
// load-bearing: without them the `Identifiable.id` requirement is nonisolated while this
// `@MainActor` class's `id` getter is isolated, which Swift 6 strict concurrency flags as a
// data-race-crossing conformance (#ConformanceIsolation).

import SlopDeskWorkspaceModel
@testable import SlopDeskWorkspaceCore

/// A `PaneSessionHandle` that RECORDS the bytes/text routed to it (so the backend's verbatim+quoted cd /
/// shim / send-keys output is observable) and serves a seeded scrollback (so `pane capture` is observable).
@MainActor
final class RecordingPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false
    private(set) var sentText: [String] = []
    private(set) var sentBytes: [[UInt8]] = []
    var scrollback: [String] = []

    init(_ spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
    func sendText(_ text: String) { sentText.append(text) }
    func sendBytes(_ bytes: [UInt8]) { sentBytes.append(bytes) }
    func captureScrollback(lines count: Int) -> [String] {
        guard count > 0 else { return [] }
        return Array(scrollback.suffix(count))
    }
}
