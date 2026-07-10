#if os(macOS)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE dispatch-decision + bookkeeping for the daemon's per-channel session registry (Stage S3).
///
/// The session MINTING itself (SCShareableContent + ``SlopDeskVideoHostSession`` + capture/encode) is
/// GUI-only and HANGS headlessly, so it is NEVER exercised here — only the registry's PURE concern:
/// "first datagram for a new channelID + is it a hello? → mint; an existing lane → deliver; an
/// unbound non-hello → drop" (``VideoMuxSessionRegistry/decide(channelID:channel:data:)``), plus the
/// sink-table register/retire bookkeeping that makes the §2 asymmetry (two panes, two windows, one
/// flow) work. The mint factory injected here is never invoked by `decide`.
final class VideoMuxSessionRegistryTests: XCTestCase {
    /// A registry whose mint factory FAILS the test if ever called from a `decide`-only path.
    private func makeRegistry(_ table: VideoMuxSinkTable = VideoMuxSinkTable()) -> VideoMuxSessionRegistry {
        VideoMuxSessionRegistry(sinkTable: table) { _, _ in
            throw Self.MintNotExpected()
        }
    }

    private struct MintNotExpected: Error {}

    private func hello(windowID: UInt32) -> Data {
        VideoControlMessage.hello(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedWindowID: windowID,
            viewport: VideoSize(width: 100, height: 100),
        ).encode()
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

    /// One ordered lane-lifecycle event a failing mint produces — REFUSAL must precede FORGET
    /// (after `forgetLane` the transport has dropped the bootstrap hello's reply-flow stamp, so a
    /// later send has no flow to ride).
    private enum LaneEvent: Equatable {
        case refusal(UInt32, Data)
        case forgot(UInt32)
    }

    /// Lock-protected ORDERED recorder shared by the `@Sendable` sendControl + forgetLane closures.
    private final class LaneEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LaneEvent] = []
        func append(_ e: LaneEvent) { lock.withLock { events.append(e) } }
        var all: [LaneEvent] { lock.withLock { events } }
    }

    func testMintFailureSendsOneTerminalRefusalThenForgetsLane() async {
        // FINDING A (mux mint failure was a SILENT drop): when the mint factory THROWS (window gone
        // between sessions / malformed hello), the old catch only cleaned up host-side — the client
        // got NOTHING back, so its FSM sat `.connecting` and resendHello() re-drove the same doomed
        // mint every ≤5 s forever (black pane; the stall scrim never arms because `streaming` is
        // false). `dispatch` must answer the arrival flow with a TERMINAL refusal — the EXISTING
        // `helloAck(accepted: false)` message, no new wire format — exactly once, BEFORE
        // forgetLane(channelID) drops the reply-flow stamp the bootstrap hello left (send-after-
        // forget has no flow to ride). forgetLane still runs so the transport's
        // channelMediaConn/channelCursorConn entries do not leak.
        let table = VideoMuxSinkTable()
        let events = LaneEventRecorder()
        let registry = VideoMuxSessionRegistry(
            sinkTable: table,
            forgetLane: { events.append(.forgot($0)) },
            sendControl: { id, data in events.append(.refusal(id, data)) },
        ) { _, _ in
            throw MintNotExpected() // simulate the window-gone / malformed-hello mint failure
        }
        await registry.dispatch(channelID: 9, channel: .control, data: hello(windowID: 404))

        let refusals = events.all.compactMap { event -> Data? in
            guard case let .refusal(id, payload) = event else { return nil }
            XCTAssertEqual(id, 9, "the refusal answers the failing lane, not a sibling")
            return payload
        }
        XCTAssertEqual(refusals.count, 1, "exactly ONE refusal datagram reaches the client flow")
        guard let payload = refusals.first,
              let message = try? VideoControlMessage.decode(payload),
              case let .helloAck(accepted, streamID, _, _, _, _) = message
        else {
            XCTFail("the refusal must decode as an existing-wire helloAck, got \(refusals)")
            return
        }
        XCTAssertFalse(accepted, "the refusal is TERMINAL: helloAck(accepted: false)")
        XCTAssertEqual(streamID, 0, "a refused hello negotiates nothing")
        XCTAssertEqual(
            events.all, [.refusal(9, payload), .forgot(9)],
            "refusal FIRST (while the reply flow is still stamped), forget-lane AFTER — and both exactly once",
        )
        // The lane is left clean (not half-minted): a fresh hello re-mints normally once the
        // window is back (reconnect path).
        let redo = await registry.decide(channelID: 9, channel: .control, data: hello(windowID: 404))
        XCTAssertEqual(redo, .mint(channelID: 9))
    }

    func testSinkTableRoutesEachChannelToItsOwnSink() {
        // The shared sink table is the demux: each channelID's datagrams go to ITS sink only.
        let table = VideoMuxSinkTable()
        let a = Recorder()
        let b = Recorder()
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

    // C6 BUG A: `liveChannelIDs` is the VD-termination policy's "which lanes are live sessions"
    // snapshot input — the registered-sink set (a lane's sink registers inside session.start and
    // unregisters on retire), so it must mirror register/unregister exactly.
    func testLiveChannelIDsMirrorRegisteredSinks() async {
        let table = VideoMuxSinkTable()
        let registry = makeRegistry(table)
        var live = await registry.liveChannelIDs
        XCTAssertEqual(live, [])
        table.register(4) { _, _ in }
        table.register(11) { _, _ in }
        live = await registry.liveChannelIDs
        XCTAssertEqual(live, [4, 11])
        await registry.retire(11)
        live = await registry.liveChannelIDs
        XCTAssertEqual(live, [4])
    }
}
#endif
