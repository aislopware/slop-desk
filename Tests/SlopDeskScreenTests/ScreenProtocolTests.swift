import SlopDeskScreen
import XCTest

/// hostd's END of the screend wire — the encoder and the reply decoder.
///
/// The behaviour of the SERVICE is pinned in `rust/slopdesk-screend`, where it is implemented;
/// re-asserting any of it here would be the cross-language mirror this tree forbids. What is
/// testable on this side is the byte layout it emits and the answers it accepts, which is exactly
/// what a wire END is.
final class ScreenProtocolTests: XCTestCase {
    func testRequestLayoutIsBigEndianAndLengthPrefixed() throws {
        let frame = try ScreenWire.encodeRequest(
            verb: .feed,
            flags: ScreenWire.flagReset,
            rows: 24,
            cols: 80,
            pane: "ab",
            raw: Data([0xDE, 0xAD]),
        )
        // len | verb | flags | rows | cols | paneLen | pane | raw
        XCTAssertEqual([UInt8](frame), [
            0, 0, 0, 12,
            ScreenVerb.feed.rawValue,
            ScreenWire.flagReset,
            0, 24,
            0, 80,
            0, 2,
            0x61, 0x62,
            0xDE, 0xAD,
        ])
    }

    /// The length counts everything after itself — the property that keeps a stream framed.
    func testDeclaredLengthCoversTheWholeBody() throws {
        let frame = try ScreenWire.encodeRequest(verb: .collapse, raw: Data(repeating: 0x41, count: 5000))
        let declared = Int(frame[0]) << 24 | Int(frame[1]) << 16 | Int(frame[2]) << 8 | Int(frame[3])
        XCTAssertEqual(declared, frame.count - 4)
        XCTAssertEqual(declared, 8 + 5000)
    }

    func testAFrameLargerThanTheServiceWillReadIsRefusedHere() {
        let raw = Data(count: ScreenWire.maximumFrameBytes + 1)
        XCTAssertThrowsError(try ScreenWire.encodeRequest(verb: .compose, rows: 1, cols: 1, raw: raw)) { error in
            guard case ScreenWire.WireError.frameTooLarge = error else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    func testAPaneKeyIsEncodedAsUTF8Bytes() throws {
        let frame = try ScreenWire.encodeRequest(verb: .forget, pane: "é")
        XCTAssertEqual([UInt8](frame.suffix(2)), [0xC3, 0xA9])
        XCTAssertEqual(frame[10], 0, "paneLen high byte")
        XCTAssertEqual(frame[11], 2, "two BYTES, not one character")
    }

    func testReplyDecodeSplitsStatusFromPayload() throws {
        let (status, payload) = try ScreenWire.decodeReply(Data([0, 0x68, 0x69]))
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(payload, Data([0x68, 0x69]))
    }

    func testAnEmptyReplyAndAnUnknownStatusAreRejectedRatherThanGuessed() {
        XCTAssertThrowsError(try ScreenWire.decodeReply(Data()))
        XCTAssertThrowsError(try ScreenWire.decodeReply(Data([9])))
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

    /// herdr's `detection_text`: trailing blank rows dropped, one trailing newline, `""` when the
    /// screen is blank. An interior blank line is CONTENT and stays.
    func testDetectionTextDropsTrailingBlanksAndKeepsInteriorOnes() {
        XCTAssertEqual(snapshot(["ab", "", "cd", "", ""]).detectionText, "ab\n\ncd\n")
        XCTAssertEqual(snapshot(["only"]).detectionText, "only\n")
        XCTAssertEqual(snapshot(["", "", ""]).detectionText, "")
        XCTAssertEqual(snapshot([]).detectionText, "")
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
