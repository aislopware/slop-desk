import Darwin
import XCTest
@testable import SlopDeskSupervisor

/// hostd's half of the supervisor channel: frame it, and read what superd sends.
///
/// ## What is deliberately NOT here
/// Decoding a *request* and resolving superd's *paths* are superd's jobs, and superd is Rust —
/// `rust/slopdesk-superd/src/protocol.rs` and `paths.rs` own those, with their own tests. Swift
/// cannot even express them any more: ``SupervisorRequest`` is `Encodable` only. So the reply
/// samples below are JSON literals rather than encoded Swift values — that is what actually
/// arrives on the socket, and building it from a Swift type would only be testing Swift against
/// itself.
final class SupervisorProtocolTests: XCTestCase {
    private var ends: [Int32] = [-1, -1]

    override func setUpWithError() throws {
        var pair: [Int32] = [0, 0]
        try XCTSkipIf(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) != 0, "socketpair unavailable")
        ends = pair
    }

    override func tearDown() {
        for end in ends where end >= 0 { close(end) }
        ends = [-1, -1]
    }

    // MARK: - Framing

    func testFrameRoundTripsTheEncodedRequest() throws {
        let request = SupervisorRequest(
            id: 7,
            verb: SupervisorProtocol.Verb.hello,
            hello: HelloRequest(client: "test"),
        )
        let encoded = try SupervisorCodec.encode(request)
        try SupervisorFrame.write(socket: ends[0], body: encoded)
        let (tag, body, descriptor) = try SupervisorFrame.read(socket: ends[1])
        XCTAssertEqual(tag, SupervisorFrame.tagPlain)
        XCTAssertNil(descriptor)
        XCTAssertEqual(body, encoded)

        // The bytes superd will parse, spelled out — this is the side of the contract Swift owns.
        let text = try XCTUnwrap(String(bytes: body, encoding: .utf8))
        XCTAssertTrue(text.contains(#""verb":"hello""#), text)
        XCTAssertTrue(text.contains(#""client":"test""#), text)
    }

    /// Two frames back to back must not bleed into each other — the tag/length split is the only
    /// thing separating them on a `SOCK_STREAM`.
    func testBackToBackFramesStayDistinct() throws {
        let first = try SupervisorCodec.encode(
            SupervisorRequest(id: 1, verb: SupervisorProtocol.Verb.list),
        )
        let second = try SupervisorCodec.encode(SupervisorRequest(
            id: 2,
            verb: SupervisorProtocol.Verb.adopt,
            adopt: AdoptRequest(paneID: "pane-b"),
        ))
        try SupervisorFrame.write(socket: ends[0], body: first)
        try SupervisorFrame.write(socket: ends[0], body: second)

        XCTAssertEqual(try SupervisorFrame.read(socket: ends[1]).body, first)
        XCTAssertEqual(try SupervisorFrame.read(socket: ends[1]).body, second)
    }

    /// The `spawn`/`adopt` reply body, as superd writes it, decoded into the record hostd acts on.
    ///
    /// Only the BODY: the descriptor riding the same frame cannot be staged here, because Swift no
    /// longer has a sender that can attach one. That half is proven against the real daemon, in
    /// `SupervisedPaneSurvivalTests` and every `PTYProcessTests` spawn.
    func testASpawnReplyBodyDecodesToAPaneRecord() throws {
        let body = Array(#"""
        {"id":3,"status":"ok","pane":{"paneID":"pane-a","sessionID":"session-a","pid":4242,
        "executable":"/bin/zsh","cwd":"/tmp","rows":24,"cols":80,"spawnedAt":1700000000,
        "attached":true}}
        """#.utf8)
        try SupervisorFrame.write(socket: ends[0], body: body)
        let received = try SupervisorFrame.read(socket: ends[1])
        XCTAssertNil(received.descriptor)

        let decoded = try SupervisorCodec.decodeReply(received.body)
        XCTAssertEqual(decoded.pane?.pid, 4242)
        XCTAssertEqual(decoded.pane?.paneID, "pane-a")
        XCTAssertEqual(decoded.pane?.attached, true)
    }

    func testOversizedBodyIsRefusedNotTruncated() {
        let body = [UInt8](repeating: 0, count: SupervisorFrame.maximumBodyBytes + 1)
        XCTAssertThrowsError(try SupervisorFrame.write(socket: ends[0], body: body)) { error in
            guard case SupervisorFrame.FrameError.bodyTooLarge = error else {
                return XCTFail("expected bodyTooLarge, got \(error)")
            }
        }
    }

    // MARK: - The packed bodies, which are `slopdesk-superwire` behind a span record

    // The LAYOUT and every validate-then-drop case live there. What can only fail here is the
    // slicing: the door answers byte offsets into a buffer this side owns, and an off-by-one is
    // silent — the pane id renders, at the right length, naming the wrong terminal.

    func testAnOutputBodyIsCutAtTheOffsetsTheDoorNamed() throws {
        // Assembled field by field, so the meaning of each byte is legible where it is asserted.
        var body: [UInt8] = [0, 6]
        body += Array("pane-7".utf8)
        body += [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        body += Array("hello".utf8)

        let decoded = try XCTUnwrap(SupervisorFrame.decodeOutput(body))
        XCTAssertEqual(decoded.paneID, "pane-7")
        XCTAssertEqual(decoded.offset, 0x0102_0304_0506_0708)
        XCTAssertEqual(decoded.payload, Data("hello".utf8))
    }

    func testAPaneJSONBodyIsCutTheSameWayAndBothTagsShareIt() throws {
        var body: [UInt8] = [0, 1]
        body += Array("p".utf8)
        body += Array(#"{"events":[]}"#.utf8)

        // `tagSniff` and `tagBlocks` differ only in what the JSON means, so one decode serves both.
        let decoded = try XCTUnwrap(SupervisorFrame.decodeSniff(body))
        XCTAssertEqual(decoded.paneID, "p")
        XCTAssertEqual(decoded.json, Data(#"{"events":[]}"#.utf8))
        XCTAssertNotEqual(SupervisorFrame.tagSniff, SupervisorFrame.tagBlocks)
    }

    /// A refusal is `nil`, not a half-filled tuple naming a pane that does not exist.
    func testABodyTheDoorDeclinesBecomesNil() {
        XCTAssertNil(SupervisorFrame.decodeOutput([]))
        XCTAssertNil(SupervisorFrame.decodeOutput([0, 9, UInt8(ascii: "p")]))
        XCTAssertNil(SupervisorFrame.decodeSniff([0, 9, UInt8(ascii: "p")]))
    }

    func testUnknownTagIsRejected() throws {
        try FileDescriptorPassing.send(socket: ends[0], bytes: [0x7F])
        XCTAssertThrowsError(try SupervisorFrame.read(socket: ends[1])) { error in
            guard case SupervisorFrame.FrameError.unknownTag(0x7F) = error else {
                return XCTFail("expected unknownTag, got \(error)")
            }
        }
    }

    // MARK: - Version skew, from hostd's side (docs/51 §3)

    /// Rule 1, in the direction hostd experiences it: a field a NEWER superd added must be ignored,
    /// not fatal. Without this, upgrading superd would break every hostd still running.
    func testAFieldFromANewerSuperdIsIgnored() throws {
        let json = #"""
        {"id":4,"status":"ok","hello":{"versionMajor":1,"versionMinor":9,"superdPID":321,
        "hookSocketPath":"/tmp/a.sock","futureField":true},"futureTopLevel":{"nested":1}}
        """#
        let decoded = try SupervisorCodec.decodeReply(Array(json.utf8))
        XCTAssertEqual(decoded.hello?.versionMinor, 9)
        XCTAssertEqual(decoded.hello?.superdPID, 321)
        XCTAssertEqual(decoded.hello?.hookSocketPath, "/tmp/a.sock")
        // Absent, not defaulted — hostd must be able to tell "superd said nothing" from "superd
        // said empty", because it advertises this path into every child's environment.
        XCTAssertNil(decoded.hello?.controlSocketPath)
    }

    /// Minor 8's field. superd outlives hostd's BUILD, so after an upgrade the binary on disk and
    /// the process on this socket are routinely different code — and the protocol minor cannot say
    /// which, because it moves only on a wire change (`docs/49`).
    func testTheRunningSuperdsBuildVersionArrivesOnHello() throws {
        let json = #"""
        {"id":4,"status":"ok","hello":{"versionMajor":1,"versionMinor":8,"superdPID":321,
        "buildVersion":"0.2.1"}}
        """#
        let decoded = try SupervisorCodec.decodeReply(Array(json.utf8))
        XCTAssertEqual(decoded.hello?.buildVersion, "0.2.1")
    }

    /// A superd older than minor 8 sends nothing, and "unknown" must stay distinguishable from
    /// "same" — reporting a stale superd as up to date is the silent wrong answer this removes.
    func testAnOlderSuperdSendsNoBuildVersionAndItStaysAbsent() throws {
        let json = #"""
        {"id":4,"status":"ok","hello":{"versionMajor":1,"versionMinor":7,"superdPID":321}}
        """#
        let decoded = try SupervisorCodec.decodeReply(Array(json.utf8))
        XCTAssertNil(decoded.hello?.buildVersion)
    }

    /// `unsupported` must stay distinguishable from `error`. Collapsing them turns "you are older
    /// than me" into "something went wrong", and only the first one is recoverable by falling back.
    func testUnsupportedIsDistinctFromError() throws {
        let unsupported = try SupervisorCodec
            .decodeReply(Array(#"{"id":1,"status":"unsupported","message":"no"}"#.utf8))
        let failed = try SupervisorCodec
            .decodeReply(Array(#"{"id":1,"status":"error","message":"no"}"#.utf8))
        XCTAssertEqual(unsupported.status, .unsupported)
        XCTAssertEqual(failed.status, .error)
    }

    func testNotificationUsesReservedZeroID() throws {
        let json = #"""
        {"id":0,"status":"ok","event":"exited","exited":{"paneID":"pane-a","pid":99,"code":137}}
        """#
        let decoded = try SupervisorCodec.decodeReply(Array(json.utf8))
        XCTAssertEqual(decoded.id, SupervisorReply.notificationID)
        XCTAssertEqual(decoded.event, SupervisorProtocol.Event.exited)
        XCTAssertEqual(decoded.exited?.code, 137)
    }

    // MARK: - The address

    /// The bug this whole daemon exists to fix, stated as an assertion: superd's address may not
    /// embed a pid, or a restarted hostd looks for a name the running daemon never bound
    /// (`docs/51` §1). The hook and ctl paths are superd's to name — hostd learns them from `hello`
    /// and has no opinion, which is why only one path is checked here.
    func testTheControlSocketPathContainsNoProcessID() {
        let resolved = SupervisorPaths.controlSocket(environment: [:])
        XCTAssertFalse(resolved.contains(String(getpid())), "\(resolved) embeds a pid")
        XCTAssertTrue(resolved.hasSuffix("/slopdesk-superd.sock"), resolved)

        let overridden = SupervisorPaths
            .controlSocket(environment: [SupervisorPaths.socketEnvKey: "/tmp/other.sock"])
        XCTAssertEqual(overridden, "/tmp/other.sock")
    }

    func testOverlongSocketPathIsRejectedRatherThanTruncated() {
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        XCTAssertThrowsError(try UnixSocketPath.validate(long))
        XCTAssertNoThrow(try UnixSocketPath.address(for: "/tmp/short.sock"))
    }
}
