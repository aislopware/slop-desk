// WebDebugRelay — the hostd listener that carries a mesh client's bytes to Chrome's debugging port.
//
// ## Why it exists
//
// Chrome binds `--remote-debugging-port` to `127.0.0.1` and cannot be talked out of it:
// `--remote-debugging-address=0.0.0.0` is accepted on the command line and ignored (measured
// 2026-08-05 — the socket still comes up on loopback). A SlopDesk client is elsewhere on the mesh,
// so something host-side has to carry the bytes across. That is this, and it is the same reason
// `AndroidBridgeServer` exists for the loopback socket `adb forward` opens.
//
// ## Why Network.framework here and BSD sockets there
//
// The Android bridge pumps a video stream whose producer must feel a slow consumer, so it blocks by
// design (see `AndroidSocketIO`'s note). This carries CDP: HTTP fetches of the frontend, then a
// websocket whose screencast frames are ACKED one at a time by the DevTools frontend itself, so the
// protocol already self-limits and there is no unbounded stream to back-pressure. That makes the
// callback shape a fit — and it keeps SIGPIPE, which killed hostd twice through the BSD path, out
// of this file entirely.
//
// The pump below is a near-twin of the client's `CodeSidebarLoopbackProxy`. It is copied rather than
// shared because the two live in different targets (a daemon that never links the client UI); the
// duplication is eight lines of `receive`/`send`, and factoring it would mean a new shared target
// for the daemon graph to carry.
//
// **Retargetable.** A Chrome respawn moves the browser's port; NEW connections must find it while
// the relay's own port stays put, so the client's loopback origin — and with it the DevTools
// frontend's stored layout — survives the respawn.
//
// Hang-safety: this builds real listeners and connections. No unit test may construct it; the
// manager takes it behind the ``WebDebugRelayHandle`` seam.

import Foundation
import Network
import SlopDeskTransport

/// The manager's view of a relay — a port to publish, a target to move, and a way to stop.
protocol WebDebugRelayHandle: AnyObject, Sendable {
    /// The port hostd is listening on, or `0` until the listener reports ready.
    var port: UInt16 { get }
    /// Points NEW connections at another loopback port (a Chrome respawn).
    func retarget(toLoopbackPort port: UInt16)
    func stop()
}

final class WebDebugRelay: WebDebugRelayHandle, @unchecked Sendable {
    private let listener: NWListener
    /// Accepts only; each relayed pair gets its own queue, for the client proxy's reason — one
    /// connection's multi-megabyte frontend fetch must not head-of-line the websocket beside it.
    private let acceptQueue = DispatchQueue(label: "slopdesk.web-relay.accept")
    private let lock = NSLock()
    private var boundPort: UInt16 = 0
    private var targetPort: UInt16

    private init(listener: NWListener, targetPort: UInt16) {
        self.listener = listener
        self.targetPort = targetPort
    }

    /// Binds an OS-chosen port on all interfaces and starts accepting. `nil` when the listener
    /// cannot even be constructed; a bind that fails later leaves ``port`` at `0`, which the
    /// manager reads as "not ready yet" and keeps reporting `starting`.
    ///
    /// No credential, on purpose: security is the WireGuard mesh (docs/DECISIONS.md), the same
    /// trust model as every other port hostd opens.
    static func start(targetLoopbackPort: UInt16) -> WebDebugRelay? {
        guard let listener = try? NWListener(using: TransportParameters.makeTCP()) else { return nil }
        let relay = WebDebugRelay(listener: listener, targetPort: targetLoopbackPort)
        listener.newConnectionHandler = { [weak relay] inbound in
            relay?.relay(inbound)
        }
        listener.stateUpdateHandler = { [weak relay] state in
            guard case .ready = state, let port = listener.port else { return }
            relay?.noteBound(port: port.rawValue)
        }
        listener.start(queue: relay.acceptQueue)
        return relay
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    func retarget(toLoopbackPort port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        targetPort = port
    }

    func stop() {
        listener.cancel()
    }

    private func noteBound(port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        boundPort = port
    }

    private var currentTarget: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return targetPort
    }

    /// One accepted connection: dial Chrome on loopback and pump both ways until either side
    /// closes. No protocol awareness — the websocket upgrade rides through untouched, which is the
    /// whole point (hostd never reads a CDP message).
    private func relay(_ inbound: NWConnection) {
        guard let port = NWEndpoint.Port(rawValue: currentTarget) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: .ipv4(.loopback), port: port, using: TransportParameters.makeTCP())
        let queue = DispatchQueue(label: "slopdesk.web-relay.pair")
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        Self.pump(from: inbound, to: outbound)
        Self.pump(from: outbound, to: inbound)
    }

    private static func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { sendError in
                    guard sendError == nil else {
                        source.cancel()
                        sink.cancel()
                        return
                    }
                    pump(from: source, to: sink)
                })
            } else if isComplete || error != nil {
                source.cancel()
                sink.cancel()
            } else {
                pump(from: source, to: sink)
            }
        }
    }
}
