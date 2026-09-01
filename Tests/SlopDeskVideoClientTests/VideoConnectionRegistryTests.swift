#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import SlopDeskVideoProtocol
import Synchronization
import XCTest
@testable import SlopDeskVideoClient

/// Refcount + share-one-flow-per-host invariants for the client UDP-mux pool (Stage S3) — the
/// analogue of the TCP `ConnectionRegistryTests`, proven with an IN-MEMORY fake flow (no socket, no
/// SCStream, no GUI). Asserts: N same-host video panes ride ONE shared flow (the headless mirror of
/// the lsof "one UDP flow" property); a sibling lane keeps the flow up when one closes; the LAST
/// lane's release tears the flow down; and per-lane channelIDs are distinct (reconnect-generation
/// safety on the host router).
@MainActor
final class VideoConnectionRegistryTests: XCTestCase {
    /// In-memory ``VideoMuxClientFlowing``: records lane registrations + sends, never opens a socket.
    private final class FakeFlow: VideoMuxClientFlowing, Sendable {
        private struct Log {
            var startCount = 0
            var closeCount = 0
            var lanes: Set<UInt32> = []
            var sends: [(VideoChannel, UInt32)] = []
        }

        private let log = Mutex(Log())
        var startCount: Int { log.withLock { $0.startCount } }
        var closeCount: Int { log.withLock { $0.closeCount } }
        var lanes: Set<UInt32> { log.withLock { $0.lanes } }
        var sends: [(VideoChannel, UInt32)] { log.withLock { $0.sends } }
        func startIfNeeded() { log.withLock { $0.startCount += 1 } }
        func registerLane(
            channelID: UInt32,
            onMedia _: @Sendable (VideoChannel, Data) -> Void,
            onCursor _: @Sendable (Data) -> Void,
        ) {
            log.withLock { _ = $0.lanes.insert(channelID) }
        }

        func unregisterLane(channelID: UInt32) { log.withLock { _ = $0.lanes.remove(channelID) } }
        func send(_: Data, on channel: VideoChannel, channelID: UInt32) {
            log.withLock { $0.sends.append((channel, channelID)) }
        }

        func close() { log.withLock { $0.closeCount += 1 } }
    }

    private func makeRegistry(_ track: @escaping (FakeFlow) -> Void = { _ in }) -> VideoConnectionRegistry {
        VideoConnectionRegistry { _, _, _ in
            let flow = FakeFlow()
            track(flow)
            return flow
        }
    }

    func testTwoSameHostPanesShareOneFlow() {
        var built: [FakeFlow] = []
        let registry = makeRegistry { built.append($0) }
        let a = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)
        let b = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)

        XCTAssertEqual(registry.sharedFlowCount, 1, "N same-host panes ride ONE shared flow (lsof property)")
        XCTAssertEqual(built.count, 1, "the flow factory ran exactly once")
        XCTAssertEqual(registry.laneCount(host: "h", mediaPort: 9000, cursorPort: 9001), 2)
        XCTAssertTrue(a.flow === b.flow)
        XCTAssertNotEqual(a.channelID, b.channelID, "each lane gets a DISTINCT channelID")
    }

    func testDistinctHostsGetDistinctFlows() {
        let registry = makeRegistry()
        _ = registry.acquire(host: "h1", mediaPort: 9000, cursorPort: 9001)
        _ = registry.acquire(host: "h2", mediaPort: 9000, cursorPort: 9001)
        XCTAssertEqual(registry.sharedFlowCount, 2, "different hosts never share a flow (same-host-only, §9)")
    }

    func testFlowSurvivesUntilLastLaneReleases() {
        var built: [FakeFlow] = []
        let registry = makeRegistry { built.append($0) }
        let a = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)
        let b = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)
        let flow = built[0]

        // First release: a SIBLING lane still rides the flow → it stays up (loss isolation on close).
        registry.release(host: "h", mediaPort: 9000, cursorPort: 9001, channelID: a.channelID)
        XCTAssertEqual(registry.sharedFlowCount, 1, "a sibling lane keeps the shared flow alive")
        XCTAssertEqual(flow.closeCount, 0)
        XCTAssertEqual(registry.laneCount(host: "h", mediaPort: 9000, cursorPort: 9001), 1)

        // Last release: the flow tears down + the pool entry drops.
        registry.release(host: "h", mediaPort: 9000, cursorPort: 9001, channelID: b.channelID)
        XCTAssertEqual(registry.sharedFlowCount, 0)
        XCTAssertEqual(flow.closeCount, 1, "the LAST lane's release closes the shared flow")
    }

    func testReacquireAfterFullReleaseBuildsAFreshFlow() {
        var built: [FakeFlow] = []
        let registry = makeRegistry { built.append($0) }
        let a = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)
        registry.release(host: "h", mediaPort: 9000, cursorPort: 9001, channelID: a.channelID)
        _ = registry.acquire(host: "h", mediaPort: 9000, cursorPort: 9001)
        XCTAssertEqual(built.count, 2, "after the flow tore down, the next pane builds a fresh one")
        XCTAssertEqual(registry.sharedFlowCount, 1)
    }
}
#endif
