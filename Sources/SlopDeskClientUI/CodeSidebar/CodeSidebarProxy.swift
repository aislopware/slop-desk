// CodeSidebarProxy — a per-project loopback TCP relay in front of the host's code-server.
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
//   2. STABLE ORIGIN — the local port is derived from the project root (FNV-1a), so the origin
//      survives code-server respawns AND app relaunches; the workbench's per-origin localStorage
//      (layout, view state) persists instead of resetting whenever the remote ephemeral port moves.
//
// Hang-safety: listeners/connections are real network objects — nothing here may be constructed in
// unit tests. The pure port-derivation lives in `CodeSidebarProxyPorts` and is the only tested part.

#if os(macOS)
import Foundation
import Network

/// Pure derivation of the loopback ports a project's proxy tries to claim. Stable across launches —
/// Swift's `Hasher` is process-seeded, so this is hand-rolled FNV-1a.
enum CodeSidebarProxyPorts {
    /// IANA dynamic range start; candidates stay in `49152 ..< 65152`.
    static let rangeBase: UInt16 = 49152
    static let rangeSize: UInt64 = 16000

    /// The `attempt`-th candidate port for a project root. Attempt 0 is THE stable port; later
    /// attempts stride away from it (bind-collision fallback — another process, or another
    /// project's hash) while staying in range.
    static func candidate(for projectRoot: String, attempt: Int) -> UInt16 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in projectRoot.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        let slot = (hash &+ UInt64(attempt) &* 131) % rangeSize
        return rangeBase + UInt16(slot)
    }
}

/// One listening loopback relay: accepts local connections and pipes each to the CURRENT target.
/// The target is retargetable — a code-server respawn moves the remote port, and NEW connections
/// (the workbench reload) must reach the new one while the local origin stays put.
final class CodeSidebarLoopbackProxy: @unchecked Sendable {
    let localPort: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "slopdesk.code-proxy")
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
    static func listening(
        onLocalPort localPort: UInt16, targetHost: String, targetPort: UInt16,
    ) async -> CodeSidebarLoopbackProxy? {
        guard let port = NWEndpoint.Port(rawValue: localPort) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }

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
            listener.start(queue: proxy.queue)
        }
    }

    func retarget(host: String, port: UInt16) {
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
    private func relay(_ inbound: NWConnection) {
        let target = currentTarget
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
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
        func resume(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// The app-lifetime pool, one proxy per project root (mirroring `CodeSidebarWebViewPool` — the
/// webview it fronts is pooled with the same key and lifetime).
@MainActor
final class CodeSidebarProxyPool {
    static let shared = CodeSidebarProxyPool()
    private var proxies: [String: CodeSidebarLoopbackProxy] = [:]

    /// The loopback endpoint fronting `host:port` for this project — binding on first use, then
    /// retargeting the existing listener (respawn/reconnect). `nil` when no candidate port binds;
    /// the caller falls back to the direct remote address (ATS's arbitrary-loads exception keeps
    /// that path alive, insecure-context toast and all).
    func endpoint(
        projectRoot: String, host: String, port: UInt16,
    ) async -> (host: String, port: UInt16)? {
        if let existing = proxies[projectRoot] {
            existing.retarget(host: host, port: port)
            return ("127.0.0.1", existing.localPort)
        }
        for attempt in 0..<8 {
            let candidate = CodeSidebarProxyPorts.candidate(for: projectRoot, attempt: attempt)
            if let proxy = await CodeSidebarLoopbackProxy.listening(
                onLocalPort: candidate, targetHost: host, targetPort: port,
            ) {
                proxies[projectRoot] = proxy
                return ("127.0.0.1", candidate)
            }
        }
        return nil
    }
}
#endif
