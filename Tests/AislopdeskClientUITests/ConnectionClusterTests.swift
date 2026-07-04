// ConnectionClusterTests — pins the connection cluster's bitrate formatting (the stream-weight
// complication), the network-health classifier behind the monogram plate's colour, and the model's
// kbps dirty-guard semantics (a ZERO is a real idle reading, kept — unlike fps, where zero is
// spurious and dropped).

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

final class ConnectionClusterTests: XCTestCase {
    func testBitrateLabelMegabitsWithOneDecimal() {
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 12400), "12.4 Mbps")
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 1000), "1.0 Mbps")
    }

    func testBitrateLabelKilobitsBelowOneMegabit() {
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 850), "850 kbps")
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 0), "0 kbps")
    }

    func testNetworkHealthClassifierThresholds() {
        // Offline wins regardless of any stale ping value.
        XCTAssertEqual(ConnectionCluster.health(isConnected: false, pingMS: 5), .offline)
        XCTAssertEqual(ConnectionCluster.health(isConnected: false, pingMS: nil), .offline)
        // Connected with no sample yet reads good (the EWMA lands within a beat).
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: nil), .good)
        // The pinned thresholds: ≤80 good, ≤180 slow, beyond bad (boundary-inclusive).
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 80), .good)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 80.1), .slow)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 180), .slow)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 180.1), .bad)
    }

    @MainActor
    func testNoteStreamKbpsKeepsZeroAndDropsNegative() {
        let model = RemoteWindowModel()
        XCTAssertNil(model.streamKbps)
        model.noteStreamKbps(2400)
        XCTAssertEqual(model.streamKbps, 2400)
        // Idle-skip: a real 0 reading REPLACES the last value (the instrument shows the stream breathing).
        model.noteStreamKbps(0)
        XCTAssertEqual(model.streamKbps, 0)
        // Nonsense negative is dropped — the last reading stands.
        model.noteStreamKbps(-5)
        XCTAssertEqual(model.streamKbps, 0)
    }
}
