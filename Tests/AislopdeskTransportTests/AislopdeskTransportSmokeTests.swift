import AislopdeskProtocol
import XCTest
@testable import AislopdeskTransport

/// Smoke tests so the target compiles and runs. Full transport behaviour
/// (framing over NWConnection, replay-after-drop, reconnect resume) lands in WF-2.
final class AislopdeskTransportSmokeTests: XCTestCase {
    func testReplayBufferCapsAreContractValues() {
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ReplayBuffer.offlineGateBytes, 4 * 1024 * 1024)
    }

    func testReplayBufferAssignsMonotonicSeqStartingAtOne() {
        var buffer = ReplayBuffer()
        XCTAssertEqual(buffer.highestSeq, 0)
        XCTAssertEqual(buffer.enqueueOutput(Data("a".utf8)).seq, 1)
        XCTAssertEqual(buffer.enqueueOutput(Data("b".utf8)).seq, 2)
        XCTAssertEqual(buffer.highestSeq, 2)
    }
}
