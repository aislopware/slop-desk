import XCTest
import Network
@testable import AislopdeskTransport

/// Asserts the canonical parameters helper sets the mandatory low-latency options.
final class TransportParametersTests: XCTestCase {

    func testMakeTCPSetsNoDelay() throws {
        let params = TransportParameters.makeTCP()
        let tcp = try XCTUnwrap(
            TransportParameters.tcpOptions(of: params),
            "canonical parameters must carry NWProtocolTCP.Options"
        )
        XCTAssertTrue(tcp.noDelay, "TCP_NODELAY (noDelay) MUST be set — Nagle can add up to ~200ms/keystroke")
    }

    func testMakeTCPEnablesKeepalive() throws {
        let params = TransportParameters.makeTCP()
        let tcp = try XCTUnwrap(TransportParameters.tcpOptions(of: params))
        XCTAssertTrue(tcp.enableKeepalive, "keepalive must be enabled to detect half-open (backgrounded iOS) sockets")
    }

    func testMakeTCPDisablesPeerToPeer() {
        let params = TransportParameters.makeTCP()
        XCTAssertFalse(params.includePeerToPeer, "AWDL peer-to-peer is irrelevant on the NetBird mesh")
    }
}
