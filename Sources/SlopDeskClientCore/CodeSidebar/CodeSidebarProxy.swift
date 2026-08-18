// CodeSidebarProxy — the loopback TCP relay in front of the host's code-server.
//
// The workbench WKWebView loads `http://127.0.0.1:<local>` instead of `http://<mesh-ip>:<remote>`,
// and this proxy pipes the bytes (HTTP + the workbench websockets are all plain TCP) to the host
// over the same mesh link the app already trusts. Two properties fall out, neither reachable by
// loading the remote address directly:
//
//   1. SECURE CONTEXT — browsers treat loopback as a-priori trustworthy, so code-server drops its
//      "insecure context" toast and the clipboard/`crypto.subtle` APIs work, with no TLS anywhere
//      (a self-signed cert would need trust-override plumbing in the webview AND still change
//      origin per respawn; security remains the WireGuard mesh, per invariant).
//   2. STABLE ORIGIN — the local port is a fixed FNV-1a derivation, so the origin survives
//      code-server respawns AND app relaunches; the workbench's per-origin storage (layout, view
//      state — keyed per folder within it) persists instead of resetting whenever the remote
//      ephemeral port moves. ONE relay for the whole app: the host runs one shared code-server,
//      every project rides the same origin and names its folder in the `?folder=` query.
//
// Hang-safety: listeners/connections are real network objects — nothing here may be constructed in
// unit tests. The pure port-derivation lives in `CodeSidebarProxyPorts` and is the only tested part.
//
// Loopback is loopback on both platforms — the relay is Foundation and Network, and both reasons it
// exists (a secure context, an origin that survives a respawn) are the phone's problems too.

import Foundation
import Network
import SlopDeskTransport

/// Pure derivation of the loopback ports the proxy tries to claim. Stable across launches —
/// Swift's `Hasher` is process-seeded, so this is hand-rolled FNV-1a.
package enum CodeSidebarProxyPorts {
    /// IANA dynamic range start; candidates stay in `49152 ..< 65152`.
    package static let rangeBase: UInt16 = 49152
    package static let rangeSize: UInt64 = 16000

    /// The relay's identity — hashed, not hardcoded, so the derivation stays generic and the stride
    /// fallback has somewhere sensible to walk from. ONE key: the workbench is the only host service
    /// the panel fronts with a web view. The Simulators surface used to have a second relay of its
    /// own; it is drawn natively now and dials the host's simulator server directly, so there is no
    /// second origin to keep apart.
    package static let sharedProxyKey = "slopdesk-code-sidebar"

    /// The `attempt`-th candidate port for `key`. Attempt 0 is THE stable port; later attempts
    /// stride away from it (bind-collision fallback — another process on the slot) while staying
    /// in range.
    package static func candidate(for key: String, attempt: Int) -> UInt16 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        let slot = (hash &+ UInt64(attempt) &* 131) % rangeSize
        return rangeBase + UInt16(slot)
    }
}

/// One listening loopback relay: accepts local connections and pipes each to the CURRENT target.
/// The target is retargetable — a code-server respawn moves the remote port, and NEW connections
/// (the workbench reload) must reach the new one while the local origin stays put.
///
/// Both hops are built from ``TransportParameters/makeTCP()`` — the app's ONE place for socket
/// parameters, and the reason is the same here as on every other SlopDesk socket: `TCP_NODELAY`.
/// The workbench's websocket to the remote extension host carries the chatty small writes (language
/// features, file reads, saves, search, SCM), exactly the traffic Nagle coalesces into a
/// delayed-ACK stall. This relay sat on default parameters — Nagle ENABLED on both hops — while
/// every other TCP path in the app disabled it.
package final class CodeSidebarLoopbackProxy: @unchecked Sendable {
    package let localPort: UInt16
    private let listener: NWListener
    /// Accepts only. Each relayed pair gets its OWN queue (see ``relay(_:)``) so one project's
    /// multi-megabyte workbench boot cannot head-of-line the rest: a single shared serial queue
    /// serialized every connection's completion handlers through one thread, which is precisely
    /// the cold-boot path (workbench.js alone is ~3.8 MB compressed, alongside the nls bundle, the
    /// stylesheet, icon fonts and the extension-host websocket).
    private let acceptQueue = DispatchQueue(label: "slopdesk.code-proxy.accept")
    private let lock = NSLock()
    private var targetHost: String
    private var targetPort: UInt16

    private init(listener: NWListener, localPort: UInt16, targetHost: String, targetPort: UInt16) {
        self.listener = listener
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Binds `127.0.0.1:<localPort>` and resolves once the listener is READY (or nil on failure —
    /// EADDRINUSE etc. arrive asynchronously and an NWListener never recovers from `.failed`, so
    /// the caller must move to the next candidate port).
    package static func listening(
        onLocalPort localPort: UInt16, targetHost: String, targetPort: UInt16,
    ) async -> CodeSidebarLoopbackProxy? {
        guard let port = NWEndpoint.Port(rawValue: localPort) else { return nil }
        guard let listener = try? NWListener(using: listenerParameters(boundTo: port)) else { return nil }

        let proxy = CodeSidebarLoopbackProxy(
            listener: listener, localPort: localPort, targetHost: targetHost, targetPort: targetPort,
        )
        listener.newConnectionHandler = { [weak proxy] inbound in
            proxy?.relay(inbound)
        }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.resume { continuation.resume(returning: proxy) }
                case .failed,
                     .cancelled:
                    listener.cancel()
                    resumed.resume { continuation.resume(returning: nil) }
                case .setup,
                     .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: proxy.acceptQueue)
        }
    }

    /// Parameters for the LOOPBACK side (the listener the workbench dials). Building `NWParameters`
    /// creates no socket, so both factories are directly unit-testable — the point being that the
    /// `noDelay` these inherit from ``TransportParameters/makeTCP()`` can never be silently dropped
    /// by a future edit reaching for `NWParameters.tcp`.
    package static func listenerParameters(boundTo port: NWEndpoint.Port) -> NWParameters {
        let parameters = TransportParameters.makeTCP()
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// Parameters for the MESH side (the connection out to the host's code-server).
    package static func outboundParameters() -> NWParameters { TransportParameters.makeTCP() }

    package func retarget(host: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        targetHost = host
        targetPort = port
    }

    private var currentTarget: (host: String, port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (targetHost, targetPort)
    }

    /// One accepted local connection: dial the current target, then pump bytes both ways until
    /// either side closes. No protocol awareness — websocket upgrades ride through untouched.
    /// Both ends of the pair share ONE fresh serial queue: ordering within the pair is preserved,
    /// while a different pair's transfer runs on its own thread (the workbench opens several
    /// parallel connections per origin, and the boot fetches are megabytes apiece).
    private func relay(_ inbound: NWConnection) {
        let target = currentTarget
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(
            host: NWEndpoint.Host(target.host), port: port, using: Self.outboundParameters(),
        )
        let queue = DispatchQueue(label: "slopdesk.code-proxy.relay")
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

    /// Resume-at-most-once guard for the listener continuation (state callbacks can keep firing).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        package func resume(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// The app-lifetime holder of the relays — ONE per host service the right panel fronts. The host
/// runs one shared code-server, so every project's webview rides that service's single loopback
/// origin (differing only in `?folder=`); the simulator server gets its own.
@MainActor
package final class CodeSidebarProxyPool {
    package static let shared = CodeSidebarProxyPool()
    private var proxies: [String: CodeSidebarLoopbackProxy] = [:]

    /// The loopback endpoint fronting `host:port` for the relay named `key` (a
    /// ``CodeSidebarProxyPorts`` identity) — binding on first use, then retargeting the existing
    /// listener (respawn/reconnect). `nil` when no candidate port binds; the caller falls back to
    /// the direct remote address (ATS's arbitrary-loads exception keeps that path alive,
    /// insecure-context toast and all).
    package func endpoint(
        host: String, port: UInt16, key: String = CodeSidebarProxyPorts.sharedProxyKey,
    ) async -> (host: String, port: UInt16)? {
        if let existing = proxies[key] {
            existing.retarget(host: host, port: port)
            return ("127.0.0.1", existing.localPort)
        }
        for attempt in 0..<8 {
            let candidate = CodeSidebarProxyPorts.candidate(for: key, attempt: attempt)
            if let bound = await CodeSidebarLoopbackProxy.listening(
                onLocalPort: candidate, targetHost: host, targetPort: port,
            ) {
                proxies[key] = bound
                return ("127.0.0.1", candidate)
            }
        }
        return nil
    }
}
