import SlopDeskScreen
import XCTest

/// hostd's END of the screend wire — the MARSHALLING, which is the only part of it that is Swift.
///
/// The byte LAYOUT is `rust/slopdesk-screenwire`, where the encoder sits beside the decoder screend
/// reads it back with, so the round trip is one test rather than two languages agreeing. Asserting
/// the offsets again here is what let a second copy of the frame live in this file for a whole
/// migration stage after the first was recorded as moved.
///
/// What is left is real: the refusal reading (`0` from a §4 door means REFUSED, not "empty"), the
/// UTF-8 hand-off, and the mapping from the door's verdict codes onto ``ScreenWire/WireError``.
final class ScreenProtocolTests: XCTestCase {
    /// The door is linked and its answer is copied whole — a frame comes back the length its own
    /// prefix declares.
    func testTheEncoderDoorIsWiredAndTheFrameIsSelfConsistent() throws {
        let frame = try ScreenWire.encodeRequest(
            verb: .feed,
            flags: ScreenWire.flagReset,
            rows: 24,
            cols: 80,
            pane: "ab",
            raw: Data([0xDE, 0xAD]),
        )
        let declared = Int(frame[0]) << 24 | Int(frame[1]) << 16 | Int(frame[2]) << 8 | Int(frame[3])
        XCTAssertEqual(declared, frame.count - 4, "the length counts everything after itself")
        XCTAssertEqual(frame.count, 4 + 8 + 2 + 2)
    }

    /// A body over what the service will read comes back as `0` from the door, and the Swift side
    /// must read that as the refusal it is rather than as an empty frame.
    func testAFrameLargerThanTheServiceWillReadIsRefusedHere() {
        let raw = Data(count: ScreenWire.maximumFrameBytes + 1)
        XCTAssertThrowsError(try ScreenWire.encodeRequest(verb: .compose, rows: 1, cols: 1, raw: raw)) { error in
            guard case ScreenWire.WireError.frameTooLarge = error else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    /// A pane key crosses as its UTF-8 BYTES, not its characters — the one thing the hand-off can
    /// get wrong without the frame looking malformed.
    func testAPaneKeyCrossesAsUTF8Bytes() throws {
        let frame = try ScreenWire.encodeRequest(verb: .forget, pane: "é")
        XCTAssertEqual([UInt8](frame.suffix(2)), [0xC3, 0xA9])
        XCTAssertEqual(frame[11], 2, "two BYTES, not one character")
    }

    /// The detect payload's label crosses the same way, and an empty label is a real one rather
    /// than a refusal.
    func testAnEmptyDetectLabelIsAPayloadAndNotARefusal() throws {
        let payload = try ScreenWire.encodeDetectPayload(agent: "", raw: Data([0x41]))
        XCTAssertEqual([UInt8](payload), [0, 0, 0x41])
    }

    /// The door's verdict codes map onto the Swift errors: a status through, an empty body as
    /// truncated, an unknown byte as unknown rather than degraded to `ok`.
    func testTheReplyVerdictMapsOntoTheSwiftErrors() throws {
        let (status, payload) = try ScreenWire.decodeReply(Data([0, 0x68, 0x69]))
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(payload, Data([0x68, 0x69]))

        XCTAssertThrowsError(try ScreenWire.decodeReply(Data())) { error in
            guard case ScreenWire.WireError.truncatedReply = error else {
                return XCTFail("expected truncatedReply, got \(error)")
            }
        }
        XCTAssertThrowsError(try ScreenWire.decodeReply(Data([9]))) { error in
            guard case ScreenWire.WireError.unknownStatus(9) = error else {
                return XCTFail("expected unknownStatus(9), got \(error)")
            }
        }
    }

    // MARK: Snapshot

    func testSnapshotDecodesTheCamelCasePayloadTheServiceEmits() throws {
        let json = """
        {"rows":3,"cols":4,"cursorRow":1,"cursorCol":2,"cursorVisible":true,
         "altScreen":false,"lines":["ab","","cd"]}
        """
        let snapshot = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.rows, 3)
        XCTAssertEqual(snapshot.cursorCol, 2)
        XCTAssertEqual(snapshot.lines, ["ab", "", "cd"])
    }

    /// Trailing blank rows are dropped; an interior blank line is CONTENT and stays. That asymmetry
    /// is the whole rule — a terminal pads its grid to `rows` with empty lines, so the tail is
    /// padding and the middle is output.
    ///
    /// This used to assert against a `detectionText` property that joined with one trailing `\n`.
    /// It was the pre-port spelling of `slopdesk-screend`'s `detect::detection_text`, it had no
    /// caller but this test, and **the test was the only thing keeping it alive** — the exact way a
    /// second implementation survives a sweep that looks for callers of live code. Deleted; the
    /// trimming rule it also covered is kept here, on the property that does have a caller
    /// (`AgentControlListener` builds the `screen` verb's `text` from it, joined with no trailing
    /// newline — a convenience beside the authoritative `lines`, and never the detection anchor).
    func testTrailingBlankRowsAreDroppedAndInteriorOnesAreKept() {
        XCTAssertEqual(snapshot(["ab", "", "cd", "", ""]).linesWithoutTrailingBlanks, ["ab", "", "cd"])
        XCTAssertEqual(snapshot(["only"]).linesWithoutTrailingBlanks, ["only"])
        XCTAssertEqual(snapshot(["", "", ""]).linesWithoutTrailingBlanks, [])
        XCTAssertEqual(snapshot([]).linesWithoutTrailingBlanks, [])
    }

    // MARK: - The hello reply's two numbers

    /// The banner is the PROTOCOL identity and stays a pinned constant; the build version rides
    /// after it. screend is a `LaunchAgent` that outlives hostd's build, so this third field is how
    /// hostd tells the process on the socket from the binary an upgrade just wrote (`docs/49`).
    func testTheBuildVersionFollowsThePinnedProtocolBanner() {
        XCTAssertEqual(ScreenWire.buildVersion(fromHello: "slopdesk-screend 1 0.1.0"), "0.1.0")
        XCTAssertEqual(ScreenWire.buildVersion(fromHello: "slopdesk-screend 1 0.2.3 extra"), "0.2.3")
    }

    /// A screend that predates the field, and anything that is not screend at all, must read as
    /// absent — "unknown", never "current".
    func testAHelloWithoutABuildVersionOrWithoutTheBannerIsAbsent() {
        XCTAssertNil(ScreenWire.buildVersion(fromHello: "slopdesk-screend 1"))
        XCTAssertNil(ScreenWire.buildVersion(fromHello: ""))
        XCTAssertNil(ScreenWire.buildVersion(fromHello: "something-else 1 0.1.0"))
    }

    private func snapshot(_ lines: [String]) -> ScreenSnapshot {
        ScreenSnapshot(
            rows: lines.count, cols: 10, cursorRow: 0, cursorCol: 0,
            cursorVisible: true, altScreen: false, lines: lines,
        )
    }
}

/// The address, which is the ONE thing both ends necessarily state separately.
final class ScreenPathsTests: XCTestCase {
    func testTheOverrideWins() {
        let path = ScreenPaths.requestSocket(environment: ["SLOPDESK_SCREEND_SOCKET": "/tmp/x.sock"])
        XCTAssertEqual(path, "/tmp/x.sock")
    }

    /// An EMPTY override is not an override — it is an unset variable spelled differently, and
    /// honouring it would aim the client at `""`.
    func testAnEmptyOverrideFallsThroughToTheDefault() {
        let path = ScreenPaths.requestSocket(environment: ["SLOPDESK_SCREEND_SOCKET": ""])
        XCTAssertTrue(path.hasSuffix("/slopdesk-screend.sock"), path)
    }

    /// No pid in the name. A child that inherited the path must still find the service after a
    /// restart — the rule `scripts/check-supervisor.sh` ratchets for every socket in the tree.
    func testTheDefaultNameCarriesNoProcessIdentity() {
        let path = ScreenPaths.requestSocket(environment: [:])
        XCTAssertTrue(path.hasSuffix("/slopdesk-screend.sock"), path)
        XCTAssertFalse(path.contains(String(getpid())), path)
    }

    func testAnAbsentBinaryIsReportedAsAbsentRatherThanGuessed() {
        let resolved = ScreenPaths.binary(
            environment: ["HOME": "/nonexistent"],
            executable: nil,
        )
        XCTAssertNil(resolved)
    }

    /// The developer-loop walk is by SEARCH, not by a fixed depth. `.build/debug` is a symlink to
    /// `.build/<triple>/debug`, so a binary found next to the test bundle sits four levels under the
    /// repo root while `swift run`'s sits three — a fixed count silently resolves to nothing for one
    /// of them, and "no engine" is a passthrough that no assertion notices.
    func testTheBuildTreeWalkFindsTheEngineFromEitherDepth() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screend-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("rust/slopdesk-screend/target/release", isDirectory: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let binary = engine.appendingPathComponent("slopdesk-screend")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        for depth in [".build/debug", ".build/arm64-apple-macosx/debug"] {
            let directory = root.appendingPathComponent(depth, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let resolved = ScreenPaths.binary(
                environment: ["HOME": "/nonexistent"],
                executable: directory.appendingPathComponent("slopdesk-hostd"),
            )
            XCTAssertEqual(resolved, binary.path, depth)
        }
    }
}

/// The client's behaviour when there is no engine — the path every caller's fallback depends on.
final class ScreenClientUnavailableTests: XCTestCase {
    /// `autostart: false` with nothing bound must FAIL, not hang and not trap. Every call site
    /// turns this into a passthrough answer, so a throw here is the whole safety net.
    func testEveryVerbThrowsWhenNothingIsListening() {
        let client = ScreenClient(
            socketPath: "/nonexistent/slopdesk-screend-absent.sock",
            binaryPath: nil,
            autostart: false,
        )
        XCTAssertThrowsError(try client.hello())
        XCTAssertThrowsError(try client.collapse(Data("a\rb\n".utf8)))
        XCTAssertThrowsError(try client.compose(raw: Data("hi".utf8), rows: 4, cols: 20))
        XCTAssertThrowsError(try client.transcript(raw: Data("hi".utf8), rows: 4, cols: 20))
        XCTAssertThrowsError(try client.snapshot(raw: Data("hi".utf8), rows: 4, cols: 20))
        XCTAssertThrowsError(try client.feed(pane: "p", raw: Data(), rows: 4, cols: 20))
        // `forget` is best-effort by contract: it swallows, so a teardown path never throws.
        client.forget(pane: "p")
    }
}
