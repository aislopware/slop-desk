// AndroidBridgeManager — the lifecycle behind metadata verb 22.
//
// Structurally the twin of ``SimulatorServerManager``, with one difference that removes most of it:
// the Android bridge is an ``NWListener``-equivalent INSIDE hostd, not a third-party child process.
// So there is no port to learn from a log line, no readiness to probe over loopback, and no
// `starting` state to poll through — ``AndroidListener`` either binds on the spot or does not, and
// `ensure()` can answer `ready` with a live port on the very first call.
//
// What stays identical, because the reasons are identical:
//
//  - **ONE shared instance, lazily.** Android devices are a machine resource. One host has one `adb`
//    server and one set of AVDs, and every pane, project and client sees the same set through the
//    same bridge — so, like verb 21 and unlike verb 18, `ensure()` takes no project root.
//  - **`ensure()` never waits.** It sits on a metadata queue answering an RPC whose client-side
//    timeout is 5 s.
//  - **No auth token.** The bridge binds `0.0.0.0` with no credential: security is the WireGuard
//    mesh (`docs/DECISIONS.md`).
//  - **Crash recovery is implicit**: a bridge whose listener died is dropped and rebuilt on the next
//    `ensure()`.

import Foundation
import SlopDeskProtocol

/// Supervises the host's one Android bridge.
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes race.
final class AndroidBridgeManager: @unchecked Sendable {
    /// Resolves the host's Android tooling; `nil` ⇒ no `adb`, so no panel.
    typealias ToolchainLocator = @Sendable () -> AndroidToolchain?
    /// Builds and starts a bridge on an ephemeral port; `nil` ⇒ the bind failed.
    typealias BridgeFactory = @Sendable (AndroidToolchain) -> AndroidBridgeServer?

    private let lock = NSLock()
    private var bridge: AndroidBridgeServer?
    private let locateToolchain: ToolchainLocator
    private let makeBridge: BridgeFactory

    init(
        toolchainLocator: @escaping ToolchainLocator = { AndroidToolchain.locate() },
        bridgeFactory: @escaping BridgeFactory = AndroidBridgeManager.defaultBridgeFactory,
    ) {
        locateToolchain = toolchainLocator
        makeBridge = bridgeFactory
    }

    /// Ensures the bridge and reports where it stands right now.
    ///
    /// `unavailable` means `adb` is missing — the one piece without which there is nothing to show.
    /// A missing `emulator` binary or a missing `scrcpy-server` jar deliberately does NOT land here:
    /// a host with a phone plugged in and no emulator still has devices to list, and a host with no
    /// jar still lists and boots them. Those two report themselves per-operation, where the panel
    /// can name the missing piece against the action that wanted it.
    func ensure() -> MetadataCodec.ServiceEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let bridge {
            return MetadataCodec.ServiceEndpoint(state: .ready, port: bridge.port)
        }
        guard let toolchain = locateToolchain() else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
        }
        guard let created = makeBridge(toolchain) else {
            // A bind failure is transient (a port table under pressure), so this reports `starting`
            // and the client's poll retries — reporting `unavailable` would render the
            // install-a-missing-tool hint for a host where nothing is missing.
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        bridge = created
        return MetadataCodec.ServiceEndpoint(state: .ready, port: created.port)
    }

    /// Closes the bridge (hostd shutdown). Booted DEVICES are left alone — the user's machine state,
    /// not this process's.
    func shutdown() {
        lock.lock()
        let stranded = bridge
        bridge = nil
        lock.unlock()
        stranded?.stop()
    }

    static let defaultBridgeFactory: BridgeFactory = { toolchain in
        guard let server = AndroidBridgeServer(toolchain: toolchain) else { return nil }
        server.start()
        return server
    }
}
