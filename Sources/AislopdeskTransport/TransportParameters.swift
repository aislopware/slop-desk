import Foundation
import Network

/// Canonical `NWParameters` for every Aislopdesk PATH 1 socket.
///
/// There is exactly **one** place that builds transport parameters so the
/// mandatory low-latency settings can never be forgotten on one side of a
/// connection. Both ``HostTransport`` (the `NWListener`) and the client-side
/// ``NWMuxByteLink`` (the `NWConnection`) use this helper.
///
/// ## What it sets and why
/// - **`TCP_NODELAY`** (`NWProtocolTCP.Options.noDelay = true`). This *is*
///   `TCP_NODELAY`: it disables Nagle's algorithm. Nagle coalesces small writes
///   and can add **up to ~200 ms** to a single-keystroke echo, which is the single
///   highest-impact omission across the surveyed terminal stacks
///   (`DECISIONS.md` Mạng/transport, [17] §2.1). Mandatory on every PATH 1 socket.
/// - **TCP keepalive** (`enableKeepalive = true`, with a bounded idle/interval/count)
///   so a half-open connection — e.g. an iOS client that vanished when the OS killed
///   its TCP a few seconds after backgrounding — is detected rather than wedging a
///   session forever.
///
/// ## What it deliberately does *not* set (per [13] NetBird transport)
/// - **No app-layer TLS / crypto.** WireGuard already encrypts (ChaCha20-Poly1305)
///   and authenticates peers; a second crypto layer is redundant overhead. The wire
///   carries raw bytes.
/// - **No `requiredInterfaceType` pin.** NetBird's `utun` interface is `.other`;
///   pinning `.wiredEthernet`/`.wifi` would *drop* NetBird traffic and break the
///   connection. We let the routing table steer `100.64/10` into the tunnel.
/// - **No `serviceClass`/DSCP.** WireGuard zeroes the outer DSCP, so QoS marking is
///   inert through the tunnel.
public enum TransportParameters {
    /// TCP keepalive idle time (seconds) before the first probe.
    static let keepaliveIdleSeconds = 10
    /// Interval (seconds) between keepalive probes.
    static let keepaliveIntervalSeconds = 5
    /// Number of unanswered keepalive probes before the connection is declared dead.
    static let keepaliveCount = 3

    /// Builds the canonical TCP parameters used by both listener and client.
    ///
    /// - Returns: `NWParameters` whose TCP options have `noDelay` (TCP_NODELAY) and
    ///   keepalive enabled, with peer-to-peer (AWDL) disabled — it is irrelevant on
    ///   the NetBird mesh and only adds discovery noise.
    public static func makeTCP() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // TCP_NODELAY — disable Nagle. Mandatory (DECISIONS / [17] §2.1).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdleSeconds
        tcp.keepaliveInterval = keepaliveIntervalSeconds
        tcp.keepaliveCount = keepaliveCount

        let parameters = NWParameters(tls: nil, tcp: tcp) // tls: nil — no app crypto, raw bytes over WireGuard.
        parameters.includePeerToPeer = false // AWDL off; not used on the mesh.
        return parameters
    }

    /// Extracts the `NWProtocolTCP.Options` from a parameters object so a test can
    /// assert that ``makeTCP()`` set `noDelay` (TCP_NODELAY). Returns `nil` if the
    /// TCP options are not present (which would itself be a bug).
    public static func tcpOptions(of parameters: NWParameters) -> NWProtocolTCP.Options? {
        parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options
            ?? parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }
}
