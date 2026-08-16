import Foundation
import SlopDeskProtocol
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The two halves of the seam superd's command-block tap arrives through: the JSON decode, and the
/// translation from what the SHELL did into what a client is TOLD.
///
/// ## Why the JSON is spelled out here as a literal
/// It is the cross-language contract, and the same discipline ``SniffedEventDecodeTests`` applies to
/// the `0x04` frame. superd writes these objects (`rust/slopdesk-superd/src/blocks.rs`, hand-written
/// `Serialize`) and pins the identical strings in
/// `every_event_serialises_to_the_shape_the_client_decodes`. A rename on either side is otherwise
/// silent: a pane would simply stop reporting its commands, with nothing logged and no build error
/// on either side of the socket.
final class BlockEventDecodeTests: XCTestCase {
    private func decode(_ json: String) -> [BlockEvent]? {
        BlockEvent.decodeBatch(Data(json.utf8))
    }

    // MARK: The decode

    func testABlockDecodesFromTheShapeSuperdEmits() {
        XCTAssertEqual(
            decode(#"""
            {"blocks":[{"kind":"block","index":3,"exitCode":0,"durationMS":42,"complete":true,\#
            "outputLen":19,"commandText":"ls -la","promptOrdinal":7}]}
            """#),
            [.block(BlockMetadata(
                index: 3,
                exitCode: 0,
                durationMS: 42,
                complete: true,
                outputLen: 19,
                commandText: "ls -la",
                promptOrdinal: 7,
            ))],
        )
    }

    /// A command still running: no `D` mark yet, so no exit code and no duration. superd always
    /// sends both keys carrying `null`, so a missing field and an absent value are never told apart
    /// by which build happened to write the frame.
    func testARunningBlockDecodesToNoExitCodeAndNoDuration() {
        XCTAssertEqual(
            decode(#"""
            {"blocks":[{"kind":"block","index":0,"exitCode":null,"durationMS":null,"complete":false,\#
            "outputLen":4,"commandText":"sleep 99","promptOrdinal":1}]}
            """#),
            [.block(BlockMetadata(index: 0, complete: false, outputLen: 4, commandText: "sleep 99", promptOrdinal: 1))],
        )
    }

    func testTheSyntheticProgressStatesDecode() {
        XCTAssertEqual(
            decode(#"{"blocks":[{"kind":"progress","state":"indeterminate"},{"kind":"progress","state":"clear"}]}"#),
            [.progress(.indeterminate), .progress(.clear)],
        )
    }

    /// A badge state a NEWER superd knows stays visible as a skew rather than being guessed at:
    /// guessing `clear` would take down a spinner that should be up, and guessing the other way
    /// would leave one up forever.
    func testAnUnknownProgressStateDegradesToTheUnknownKindRatherThanAGuess() {
        XCTAssertEqual(
            decode(#"{"blocks":[{"kind":"progress","state":"halfway"}]}"#),
            [.unknown(kind: "progress")],
        )
    }

    /// Version skew, and the reason this decodes by hand: a kind a NEWER superd knows must not take
    /// the whole batch — every exit code and command line in it — down with the one member this
    /// build cannot read.
    func testAnUnknownKindIsKeptWithoutLosingItsNeighbours() {
        XCTAssertEqual(
            decode(#"""
            {"blocks":[{"kind":"weather","sky":"grey"},{"kind":"block","index":1,"exitCode":null,\#
            "durationMS":null,"complete":true,"outputLen":0,"commandText":"true","promptOrdinal":0}]}
            """#),
            [
                .unknown(kind: "weather"),
                .block(BlockMetadata(index: 1, complete: true, commandText: "true")),
            ],
        )
    }

    /// Validate-then-drop, the rule every untrusted decode here follows — and this one is only as
    /// trusted as the daemon on the far end of the socket, which may be an older build.
    func testABodyThatIsNotABatchIsRefusedRatherThanGuessed() {
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[]"))
        XCTAssertNil(decode(#"{"nope":1}"#))
        XCTAssertEqual(decode(#"{"blocks":[]}"#), [], "an empty batch is legal, merely uninteresting")
    }

    // MARK: The reply objects the three verbs answer with

    func testARecentBlockCarriesItsOutputAsBase64() {
        let reply = try? JSONDecoder().decode(BlocksReply.self, from: Data(#"""
        {"recent":[{"index":2,"commandText":"echo hi","exitCode":0,"durationMS":5,"complete":true,\#
        "output":"aGkK"}],"open":{"commandText":"tail -f log","outputLen":128},"nextIndex":4}
        """#.utf8))
        XCTAssertEqual(reply?.recent?.count, 1)
        XCTAssertEqual(reply?.recent?.first?.commandText, "echo hi")
        XCTAssertEqual(reply?.recent?.first.map { String(bytes: $0.output, encoding: .utf8) }, "hi\n")
        XCTAssertEqual(reply?.open?.commandText, "tail -f log")
        XCTAssertEqual(reply?.open?.outputLen, 128)
        XCTAssertEqual(reply?.nextIndex, 4)
    }

    /// Bytes that will not decode would be a transcript that silently lies, so an unusable body
    /// becomes an empty one rather than a guess at what was meant.
    func testAnUndecodableOutputBodyBecomesEmptyRatherThanGarbage() {
        let reply = try? JSONDecoder().decode(BlocksReply.self, from: Data(#"{"output":"!!!not base64!!!"}"#.utf8))
        XCTAssertEqual(reply?.outputBytes, [])
    }

    // MARK: The translation

    func testEachEventBecomesTheMessageItsWireTypeExpects() {
        XCTAssertEqual(
            MuxChannelSession.wireMessagesForTesting([
                .block(BlockMetadata(
                    index: 3,
                    exitCode: 1,
                    durationMS: 42,
                    complete: true,
                    outputLen: 19,
                    commandText: "false",
                    promptOrdinal: 7,
                )),
                .progress(.indeterminate),
                .progress(.clear),
            ] as [BlockEvent]),
            [
                .commandBlock(
                    index: 3,
                    exitCode: 1,
                    durationMS: 42,
                    complete: true,
                    outputLen: 19,
                    commandText: "false",
                    promptOrdinal: 7,
                ),
                .progress(state: ProgressState.indeterminate.rawValue, percent: 0),
                .progress(state: ProgressState.clear.rawValue, percent: 0),
            ],
        )
    }

    /// An unknown kind is dropped from the wire, not invented into a message: it is a fact a NEWER
    /// superd knows and this build does not, and staying quiet is the only honest answer.
    func testAnUnknownKindProducesNoWireMessage() {
        XCTAssertEqual(
            MuxChannelSession.wireMessagesForTesting([.unknown(kind: "weather")] as [BlockEvent]),
            [],
        )
    }
}
