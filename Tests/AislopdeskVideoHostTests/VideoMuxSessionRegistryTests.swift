#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost
import AislopdeskVideoProtocol

/// PURE dispatch-decision + bookkeeping for the daemon's per-channel session registry (Stage S3).
///
/// The session MINTING itself (SCShareableContent + ``AislopdeskVideoHostSession`` + capture/encode) is
/// GUI-only and HANGS headlessly, so it is NEVER exercised here — only the registry's PURE concern:
/// "first datagram for a new channelID + is it a hello? → mint; an existing lane → deliver; an
/// unbound non-hello → drop" (``VideoMuxSessionRegistry/decide(channelID:channel:data:)``), plus the
/// sink-table register/retire bookkeeping that makes the §2 asymmetry (two panes, two windows, one
/// flow) work. The mint factory injected here is never invoked by `decide`.
final class VideoMuxSessionRegistryTests: XCTestCase {

    /// A registry whose mint factory FAILS the test if ever called from a `decide`-only path.
    private func makeRegistry(_ table: VideoMuxSinkTable = VideoMuxSinkTable()) -> VideoMuxSessionRegistry {
        VideoMuxSessionRegistry(sinkTable: table) { _, _ in
            throw VideoMuxSessionRegistryTests.MintNotExpected()
        }
    }
    private struct MintNotExpected: Error {}

    private func hello(windowID: UInt32) -> Data {
        VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: windowID,
                                  viewport: VideoSize(width: 100, height: 100)).encode()
    }

    func testFirstHelloForNewChannelDecidesMint() async {
        let registry = makeRegistry()
        let decision = await registry.decide(channelID: 5, channel: .control, data: hello(windowID: 42))
        XCTAssertEqual(decision, .mint(channelID: 5))
    }

    func testNonHelloForUnknownChannelDecidesDrop() async {
        // A video/input/recovery datagram for a never-seen lane cannot be bound to a session — drop
        // (benign, never fatal, never disturbs siblings).
        let registry = makeRegistry()
        let bye = VideoControlMessage.bye.encode()
        let dropControl = await registry.decide(channelID: 8, channel: .control, data: bye)
        let dropVideo = await registry.decide(channelID: 8, channel: .video, data: Data([0x01, 0x02]))
        XCTAssertEqual(dropControl, .dropUnbound(channelID: 8))
        XCTAssertEqual(dropVideo, .dropUnbound(channelID: 8))
    }

    func testExistingLaneDecidesDeliver() async {
        // Once a lane's sink is registered (what session.start does on mint), every datagram for it
        // — hello, video, input — decides DELIVER, never re-mints.
        let table = VideoMuxSinkTable()
        let registry = makeRegistry(table)
        table.register(11) { _, _ in }
        let deliverVideo = await registry.decide(channelID: 11, channel: .video, data: Data([0xAA]))
        let deliverHello = await registry.decide(channelID: 11, channel: .control, data: hello(windowID: 1))
        XCTAssertEqual(deliverVideo, .deliver(channelID: 11))
        XCTAssertEqual(deliverHello, .deliver(channelID: 11))
    }

    func testTwoChannelsDifferentWindowsBothMintIndependently() async {
        // The §2 asymmetry: two panes on the same host watch DIFFERENT windows → two hellos with
        // different requestedWindowIDs → each is an independent MINT decision on its own channelID.
        let registry = makeRegistry()
        let d1 = await registry.decide(channelID: 1, channel: .control, data: hello(windowID: 100))
        let d2 = await registry.decide(channelID: 2, channel: .control, data: hello(windowID: 200))
        XCTAssertEqual(d1, .mint(channelID: 1))
        XCTAssertEqual(d2, .mint(channelID: 2))
    }

    func testRetireClearsLaneBookkeepingForReconnect() async {
        let table = VideoMuxSinkTable()
        let registry = makeRegistry(table)
        table.register(3) { _, _ in }
        XCTAssertTrue(table.contains(3))
        await registry.retire(3)
        XCTAssertFalse(table.contains(3))
        // After retire, the lane is "new" again — a fresh hello re-mints (reconnect path).
        let redo = await registry.decide(channelID: 3, channel: .control, data: hello(windowID: 7))
        XCTAssertEqual(redo, .mint(channelID: 3))
    }

    /// Lock-protected recorder so the `@Sendable` sink closures can record into it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [Data] = []
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var all: [Data] { lock.withLock { data } }
    }

    /// Lock-protected UInt32 recorder for the `@Sendable` forgetLane closure.
    private final class IDRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UInt32] = []
        func append(_ id: UInt32) { lock.withLock { ids.append(id) } }
        var all: [UInt32] { lock.withLock { ids } }
    }

    func testMintFailureForgetsLane() async {
        // When the mint factory THROWS (window gone / malformed hello), `dispatch` must call
        // forgetLane(channelID) so the shared transport drops the flow it remembered for the
        // bootstrap hello — otherwise that channelMediaConn/channelCursorConn entry leaks (the lane
        // is never admitted, so no retire/bye ever cleans it). Regression guard for that MEDIUM.
        let table = VideoMuxSinkTable()
        let forgotten = IDRecorder()
        let registry = VideoMuxSessionRegistry(sinkTable: table, forgetLane: { forgotten.append($0) }) { _, _ in
            throw MintNotExpected()   // simulate the window-gone / malformed-hello mint failure
        }
        await registry.dispatch(channelID: 9, channel: .control, data: hello(windowID: 404))
        XCTAssertEqual(forgotten.all, [9], "a failed mint must forget the lane so its flow does not leak")
        // The lane is left clean (not half-minted): a fresh hello re-mints (reconnect path).
        let redo = await registry.decide(channelID: 9, channel: .control, data: hello(windowID: 404))
        XCTAssertEqual(redo, .mint(channelID: 9))
    }

    func testSinkTableRoutesEachChannelToItsOwnSink() {
        // The shared sink table is the demux: each channelID's datagrams go to ITS sink only.
        let table = VideoMuxSinkTable()
        let a = Recorder(); let b = Recorder()
        table.register(1) { _, d in a.append(d) }
        table.register(2) { _, d in b.append(d) }
        table.sink(1)?(.video, Data([0x01]))
        table.sink(2)?(.video, Data([0x02]))
        table.sink(1)?(.input, Data([0x03]))
        XCTAssertEqual(a.all, [Data([0x01]), Data([0x03])])
        XCTAssertEqual(b.all, [Data([0x02])])
        XCTAssertEqual(table.count, 2)
        table.unregister(1)
        XCTAssertNil(table.sink(1))
        XCTAssertEqual(table.count, 1)
    }
}
#endif
