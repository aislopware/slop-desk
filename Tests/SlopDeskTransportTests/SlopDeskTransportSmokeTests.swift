import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// Smoke tests so the target compiles and runs. Full transport behaviour
/// (framing over NWConnection, replay-after-drop, reconnect resume) is covered elsewhere.
final class SlopDeskTransportSmokeTests: XCTestCase {
    func testReplayBufferCapsAreContractValues() {
        XCTAssertEqual(ReplayBuffer.maxBackupBytes, 256 * 1024 * 1024)
        XCTAssertEqual(ReplayBuffer.offlineGateBytes, 64 * 1024 * 1024)
    }

    func testReplayBufferAssignsMonotonicSeqStartingAtOne() {
        var buffer = ReplayBuffer()
        XCTAssertEqual(buffer.highestSeq, 0)
        XCTAssertEqual(buffer.enqueueOutput(Data("a".utf8)).seq, 1)
        XCTAssertEqual(buffer.enqueueOutput(Data("b".utf8)).seq, 2)
        XCTAssertEqual(buffer.highestSeq, 2)
    }
}
