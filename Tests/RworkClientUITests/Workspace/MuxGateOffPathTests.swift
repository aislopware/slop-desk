import XCTest
import Foundation
@testable import RworkClientUI
import RworkTransport

// MARK: - MuxGateOffPathTests

/// Pins the load-bearing OFF-path safety property of the TCP-mux S1 feature: with `RWORK_TCP_MUX`
/// unset (or the mux registry absent / disabled), the client session factory is the EXACT today
/// path — no shared `MuxNWConnection` is ever created, and the registry's `makeConnection` is never
/// invoked. The gate lives SOLELY at the `WorkspaceStore.liveMakeSession` construction site.
///
/// These run entirely through `liveMakeSession` + `reconcile` materialization — they never connect a
/// socket (the factory's `connect()` is what would touch the registry, and materialization is lazy,
/// docs/22 §6 lazy connect), so they are headless-safe and never instantiate a real client/host.
@MainActor
final class MuxGateOffPathTests: XCTestCase {

    /// A registry whose `makeConnection` FAILS the test if ever invoked — so any OFF-path test that
    /// accidentally took the mux branch is caught immediately. `created` reports the build count.
    private func tripwireRegistry(enabled: Bool) -> ConnectionRegistry {
        ConnectionRegistry(isEnabled: enabled) { _, _ in
            XCTFail("OFF path must NEVER build a shared mux connection")
            // Unreachable in a passing test; satisfy the type with a throw.
            throw RworkTransportError.invalidState("tripwire")
        }
    }

    func testNilRegistryYieldsTodayShapedSessionsAndNoSharedObject() async {
        // muxRegistry == nil ⇒ the factory is the caller's `{ RworkClient() }` UNCHANGED.
        let factory = WorkspaceStore.liveMakeSession(muxRegistry: nil)
        let store = WorkspaceStore(makeSession: factory)
        store.split(store.activeTab!.focusedPane, axis: .horizontal, kind: .terminal)

        // Two terminal panes materialized as today-shaped LivePaneSessions (the production handle),
        // each backed by a ConnectionViewModel + the default `{ RworkClient() }` — no shared object.
        let handles = store.allSessions
        XCTAssertEqual(handles.count, 2)
        for handle in handles {
            XCTAssertTrue(handle is LivePaneSession, "OFF path materializes the today-shaped LivePaneSession")
        }
    }

    func testDisabledRegistryNeverConsultsTheRegistry() async {
        // An explicitly DISABLED registry (gate OFF) must be ignored entirely by the factory: the
        // tripwire `makeConnection` is never called, and the pool stays empty.
        let registry = tripwireRegistry(enabled: false)
        let factory = WorkspaceStore.liveMakeSession(muxRegistry: registry)
        let store = WorkspaceStore(makeSession: factory)
        store.split(store.activeTab!.focusedPane, axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.allSessions.count, 2)
        XCTAssertEqual(registry.sharedConnectionCount, 0, "a disabled registry is never consulted (no shared connection)")
    }

    func testRegistryIsEnabledGateParsedFromEnvironment() {
        // The gate parse is shared with the host (HostTransport.muxEnabledFromEnvironment), pinned in
        // ConnectionRegistryTests; here we confirm the default (process env, no var in CI) is OFF so
        // a normal test/app run takes the byte-identical path unless the operator opts in.
        XCTAssertFalse(ConnectionRegistry.muxEnabledFromEnvironment([:]))
    }
}
