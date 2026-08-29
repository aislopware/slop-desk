#if os(macOS)
import Network
import SlopDeskNet
import XCTest
@testable import SlopDeskClientCore

/// ``CodeSidebarProxyPorts`` — the loopback proxy's pure port derivation, plus the parameter
/// factories behind both relay hops. Listeners and connections are real network objects and are
/// never constructed here; `NWParameters` itself opens no socket.
final class CodeSidebarProxyPortsTests: XCTestCase {
    func testCandidateIsStableAcrossCalls() {
        // The whole point: the SAME key maps to the SAME local port in every process, so the
        // workbench origin (and its storage) survives app relaunches. Swift's `Hasher` is
        // process-seeded and would break this — the derivation is hand-rolled FNV-1a.
        XCTAssertEqual(
            CodeSidebarProxyPorts.candidate(for: CodeSidebarProxyPorts.sharedProxyKey, attempt: 0),
            CodeSidebarProxyPorts.candidate(for: CodeSidebarProxyPorts.sharedProxyKey, attempt: 0),
        )
    }

    func testCandidatesStayInTheDynamicRange() {
        let keys = [
            CodeSidebarProxyPorts.sharedProxyKey, "/a", "/Users/x/some/deep/project",
            String(repeating: "p", count: 300),
        ]
        for key in keys {
            for attempt in 0..<8 {
                let port = CodeSidebarProxyPorts.candidate(for: key, attempt: attempt)
                XCTAssertGreaterThanOrEqual(port, CodeSidebarProxyPorts.rangeBase)
                XCTAssertLessThan(
                    UInt64(port), UInt64(CodeSidebarProxyPorts.rangeBase) + CodeSidebarProxyPorts.rangeSize,
                )
            }
        }
    }

    func testAttemptsStrideToDistinctPorts() {
        // The bind-collision fallback must actually move: every attempt for one key is distinct.
        let ports = Set((0..<8).map {
            CodeSidebarProxyPorts.candidate(for: CodeSidebarProxyPorts.sharedProxyKey, attempt: $0)
        })
        XCTAssertEqual(ports.count, 8)
    }

    func testDistinctKeysDiverge() {
        // Not a guarantee (16000 slots), but these two colliding would mean a degenerate hash.
        XCTAssertNotEqual(
            CodeSidebarProxyPorts.candidate(for: "/Users/x/alpha", attempt: 0),
            CodeSidebarProxyPorts.candidate(for: "/Users/x/beta", attempt: 0),
        )
    }

    // MARK: - Relay parameters (TCP_NODELAY on BOTH hops)

    /// The workbench's websocket to the remote extension host is small-write chatter (completions,
    /// hovers, file reads, saves, search, SCM) — Nagle's coalescing plus the peer's delayed ACK is
    /// exactly the stall that traffic cannot afford. This relay once ran on default parameters
    /// while every other TCP path in the app disabled Nagle; these two assertions are the ratchet.
    func testListenerParametersDisableNagle() throws {
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 49999))
        let parameters = CodeSidebarLoopbackProxy.listenerParameters(boundTo: port)
        let tcp = try XCTUnwrap(TransportParameters.tcpOptions(of: parameters))
        XCTAssertTrue(tcp.noDelay, "the loopback hop MUST disable Nagle")
    }

    func testOutboundParametersDisableNagle() throws {
        let tcp = try XCTUnwrap(
            TransportParameters.tcpOptions(of: CodeSidebarLoopbackProxy.outboundParameters()),
        )
        XCTAssertTrue(tcp.noDelay, "the mesh hop MUST disable Nagle")
    }

    /// The listener still has to claim its STABLE loopback port — the whole reason the relay exists
    /// (a fixed origin the workbench's per-origin storage survives on).
    func testListenerParametersKeepTheLoopbackBinding() throws {
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 49999))
        let parameters = CodeSidebarLoopbackProxy.listenerParameters(boundTo: port)
        XCTAssertTrue(parameters.allowLocalEndpointReuse)
        XCTAssertEqual(
            parameters.requiredLocalEndpoint, .hostPort(host: .ipv4(.loopback), port: port),
        )
    }
}
#endif
