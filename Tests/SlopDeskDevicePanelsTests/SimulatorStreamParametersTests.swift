// SimulatorStreamParametersTests — the socket parameters, which are the only part of
// ``SimulatorStreamConnection`` a test may touch. Building `NWParameters` creates no socket; the
// connection itself is a real network object and stays out of every test under the hang-safety rule.

#if os(macOS)
import Network
import SlopDeskNet
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorStreamParametersTests: XCTestCase {
    func testTheStreamSocketDisablesNagle() throws {
        // The upstream traffic is the definition of what Nagle ruins: a `touch1-move` every few
        // milliseconds during a drag, each a ~60-byte write. Coalesced into a delayed-ACK stall, the
        // drag arrives as a stutter. Reaching for `NWParameters.tcp` instead of the project's own
        // factory is exactly how that regresses, silently.
        let tcp = try XCTUnwrap(
            TransportParameters.tcpOptions(of: SimulatorStreamConnection.parameters()),
            "the stream socket must be built from TransportParameters.makeTCP()",
        )
        XCTAssertTrue(tcp.noDelay, "the gesture path MUST disable Nagle")
    }

    func testTheWebsocketProtocolSitsAtopTheTCPStack() {
        let options = SimulatorStreamConnection.parameters()
            .defaultProtocolStack.applicationProtocols
            .compactMap { $0 as? NWProtocolWebSocket.Options }
        XCTAssertEqual(options.count, 1)
    }

    func testTheStackStoresACopySoOptionFlagsCannotBeSetThroughIt() throws {
        // The measurement behind ``SimulatorStreamConnection/parameters()`` not setting
        // `autoReplyPing`: Network.framework copies the options object on insert, and the copy reads
        // flags back as defaults. Anything configured that way is silently inert — here, a keepalive
        // that looks handled and is not. Pinned so a future edit that "restores" the flag has to
        // confront this first.
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let stored = try XCTUnwrap(
            parameters.defaultProtocolStack.applicationProtocols
                .compactMap { $0 as? NWProtocolWebSocket.Options }.first,
        )
        XCTAssertFalse(stored === options)
        XCTAssertFalse(stored.autoReplyPing)
    }

    func testAnUnknownMessageTypeIsRecognisableAsSuch() {
        // The connection drops these rather than forwarding them; the predicate it gates on is here.
        XCTAssertTrue(SimulatorStreamMessage.unknown(0x09).isUnknown)
        XCTAssertFalse(SimulatorStreamMessage.jpeg(Data([0x01])).isUnknown)
        XCTAssertFalse(SimulatorStreamMessage.accessUnit(Data([0x01]), isKeyframe: true).isUnknown)
    }
}
#endif
