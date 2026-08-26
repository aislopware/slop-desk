import CSlopDeskFFI
import Network

/// Canonical `NWParameters` for every SlopDesk PATH 1 socket.
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
///   (`DECISIONS.md` Network / transport, [17] §2.1). Mandatory on every PATH 1 socket.
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
    ///
    /// Asked for, not written down. The listener that must agree with these three numbers is
    /// `slopdesk-hostnet`, a separate program, and a ladder configured on one end only leaves a
    /// half-open connection that neither end reports. `slopdesk_wire::transport` declares them
    /// once and both ends spend them.
    ///
    /// Still NOT the video path's `KEEPALIVE_INTERVAL_SECONDS`, which happens to be 5 as well:
    /// that one is an application datagram the client sends over UDP to hold a NAT mapping open,
    /// this one is a kernel TCP probe. Same number, two unrelated laws — hence the `TCP_` prefix
    /// on the wire side, and no shared door between them.
    static let keepaliveIdleSeconds = slopdesk_wire_constant(3)
    /// Interval (seconds) between keepalive probes.
    static let keepaliveIntervalSeconds = slopdesk_wire_constant(4)
    /// Number of unanswered keepalive probes before the connection is declared dead.
    static let keepaliveCount = slopdesk_wire_constant(5)

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
