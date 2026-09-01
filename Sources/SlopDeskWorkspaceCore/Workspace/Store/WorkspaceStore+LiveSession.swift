import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskNet
import SlopDeskTransport
import SlopDeskWorkspaceModel

// MARK: - Production session factory

/// The PRODUCTION session factory — the one `makeSession` a test substitutes for.
public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with a mux-backed client
    /// factory and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as
    /// `makeSession` so tests can substitute `{ FakePaneSession($0.spec) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeInspector: builds the read-only `InspectorClient` for a terminal endpoint (subscribed
    ///     dynamically once a `claude` is detected), or `nil` when no second channel is available.
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    ///   - muxRegistry: the per-host shared-connection pool. Every `SlopDeskClient` is backed by a
    ///     logical channel over the per-host shared mux connection (refcounted by the registry).
    static func liveMakeSession(
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient? = liveMakeInspector,
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
    ) -> @MainActor (PaneMaterialization) -> any PaneSessionHandle {
        // Every pane is backed by a logical channel over the per-host shared mux connection
        // (refcounted by the registry), connecting to the ONE app-global `target`. This is the SOLE
        // client-side construction site; nothing on the per-message path is touched.
        let effectiveMakeClient = muxBackedClientFactory(registry: muxRegistry)
        return { seed in
            LivePaneSession.make(
                paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                makeClient: effectiveMakeClient, makeInspector: makeInspector, target: target,
            )
        }
    }

    /// Builds a `@Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient` whose sessions route over
    /// the shared mux connection pooled by `registry`.
    ///
    /// The pool is handed to the session's Rust driver, which opens its own channel on it at
    /// `connect()` and releases it at `close()` — so the shared connection is torn down only when the
    /// LAST pane's channel goes, and every pane to one host keeps riding ONE mux.
    ///
    /// The `resumeSeed` rides `init`, which is the whole point of it being an init parameter: seeding
    /// a restored pane's identity AFTER this factory returns — a fire-and-forget
    /// `Task { await c.seed(…) }` — is ordered against nothing, and a cold-launch restore of many
    /// panes could lose the race and start a fresh session instead of reattaching
    /// (`docs/DECISIONS.md`). `nil` = a fresh / never-restored pane (no seed, no race).
    private static func muxBackedClientFactory(
        registry: ConnectionRegistry,
    ) -> @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient {
        { @Sendable resumeSeed in
            SlopDeskClient(registry: registry, resumeSeed: resumeSeed)
        }
    }

    /// Builds the production read-only ``InspectorClient`` for a terminal pane's `endpoint` (subscribed
    /// dynamically once a `claude` is detected in it).
    ///
    /// ### Guardrail (docs/22 §7): the LIVE network inspector path is NOT runtime-proven
    /// PATH 1 (the terminal byte-pipeline) is proven; the inspector second channel (NWConnection #2) is wired
    /// cleanly but **no host-side inspector serving / port exists yet** (no `slopdesk-hostd` inspector daemon
    /// to invent). So this returns a *ready, lazily-connecting* client rather than eagerly dialing: it stands
    /// up an ``NWByteChannel`` over a fresh `NWConnection` to `host:inspectorPort` (the ``inspectorPort(for:)``
    /// convention) but does NOT `start()` it — the channel connects on the first `send`/`subscribe`, driven by
    /// ``LivePaneSession/subscribeInspector()`` (the leaf's `.task` on appear). Against a host that
    /// doesn't serve the port the connection never completes its handshake and the fold yields no cards — the
    /// terminal is unaffected. The FOLD logic is fully unit-testable in-process via `LoopbackByteChannel.pair()`
    /// + ``InspectorClient/init(channel:)`` (docs/22 §8), independent of this builder. Real-network inspector
    /// serving is a hardware followup.
    ///
    /// Returns `nil` only when no inspector port can be derived (terminal on the top port).
    @MainActor
    static func liveMakeInspector(_ target: ConnectionTarget) -> InspectorClient? {
        guard let port = inspectorPort(for: target),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: nwPort,
            using: NWByteChannel.parameters(),
        )
        // The channel connects lazily: NWByteChannel.start() is idempotent and is triggered by the
        // first send (the `subscribe(fromSeq:)` in LivePaneSession.subscribeInspector). We do not start
        // it here so a plain terminal (no claude detected) opens no inspector socket.
        let channel = NWByteChannel(connection: connection, label: "slopdesk.inspector.channel")
        return InspectorClient(channel: channel)
    }
}
