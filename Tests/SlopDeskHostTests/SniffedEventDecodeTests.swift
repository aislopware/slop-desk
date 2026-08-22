import Foundation
import SlopDeskProtocol
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The two halves of the seam superd's sniffer arrives through: the JSON decode, and the
/// translation from what the shell SAID into what a client is TOLD.
///
/// ## Why the JSON is spelled out here as a literal
/// It is the cross-language contract. superd writes these objects
/// (`rust/slopdesk-superd/src/sniffer.rs`, hand-written `Serialize`) and pins the same strings in
/// `every_event_serialises_to_the_shape_the_client_decodes`. A rename on either side is otherwise
/// silent: hostd would decode an event with a missing field and a pane would simply stop reporting
/// its titles, with nothing logged. Two literal copies of the same bytes is the cheapest way to
/// make that loud, and it is the same discipline the golden corpus applies to the wire itself.
final class SniffedEventDecodeTests: XCTestCase {
    private func decode(_ json: String) -> [SniffedEvent]? {
        SniffedEvent.decodeBatch(Data(json.utf8))
    }

    // MARK: The decode

    func testEveryKindDecodesFromTheShapeSuperdEmits() {
        XCTAssertEqual(decode(#"{"events":[{"kind":"title","value":"x"}]}"#), [.title("x")])
        XCTAssertEqual(decode(#"{"events":[{"kind":"cwd","value":"/x"}]}"#), [.cwd("/x")])
        XCTAssertEqual(decode(#"{"events":[{"kind":"progress","value":"4;1;50"}]}"#), [.progress("4;1;50")])
        XCTAssertEqual(decode(#"{"events":[{"kind":"bell"}]}"#), [.bell])
        XCTAssertEqual(decode(#"{"events":[{"kind":"status","state":"running"}]}"#), [.commandRunning])
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"status","state":"idle","exitCode":-1,"durationMS":7}]}"#),
            [.commandIdle(exitCode: -1, durationMS: 7)],
        )
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"notification","title":"t","body":"b"}]}"#),
            [.notification(title: "t", body: "b")],
        )
    }

    /// The code-less `133;D`. superd always sends the key, carrying `null`, so that a missing field
    /// and an absent exit code are never told apart by which build happened to write it.
    func testACodelessIdleDecodesToNoExitCode() {
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"status","state":"idle","exitCode":null,"durationMS":0}]}"#),
            [.commandIdle(exitCode: nil, durationMS: 0)],
        )
    }

    /// The state discriminator, pinned as the two literals superd writes rather than as "idle and
    /// everything else". This decode used to `guard … == "idle" else { return .commandRunning }`,
    /// so ANY other string — a rename, a third state from a newer superd, a typo, a missing key —
    /// read as a command still running: the spinner would never come down, and both suites stayed
    /// green because each end only ever tested itself.
    func testAnUnknownStateIsNeverSilentlyReadAsRunning() {
        // The two superd actually writes still mean exactly what they meant.
        XCTAssertEqual(decode(#"{"events":[{"kind":"status","state":"running"}]}"#), [.commandRunning])
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"status","state":"idle","exitCode":0,"durationMS":1}]}"#),
            [.commandIdle(exitCode: 0, durationMS: 1)],
        )
        // Everything else asserts NOTHING. `kind: "status"` is unambiguous — `status` is a kind this
        // build knows, so it can only mean the state was the part it could not read.
        for state in [#""stalled""#, #""finished""#, #""IDLE""#, "null", "7"] {
            XCTAssertEqual(
                decode(#"{"events":[{"kind":"status","state":\#(state)}]}"#),
                [.unknown(kind: "status")],
                "state \(state) must not be guessed at",
            )
        }
        // A missing `state` is the same answer, and used to be the worst of them: it read as a
        // command running that no shell had ever reported starting.
        XCTAssertEqual(decode(#"{"events":[{"kind":"status"}]}"#), [.unknown(kind: "status")])
        // And it costs its neighbours nothing, exactly as an unknown KIND does not.
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"status","state":"stalled"},{"kind":"bell"}]}"#),
            [.unknown(kind: "status"), .bell],
        )
    }

    /// An unreadable state reaches the wire the way any other skew does — as nothing at all. The
    /// client keeps the state it already had, which for the rename this test exists for means a
    /// finished command sits there spinning rather than being quietly marked done.
    func testAnUnknownStateProducesNoWireMessage() {
        XCTAssertEqual(
            MuxChannelSession.wireMessagesForTesting([.unknown(kind: "status"), .bell]),
            [.bell],
        )
    }

    /// Version skew, and the reason this decodes by hand: a kind a NEWER superd knows must not take
    /// the whole batch — every title and exit code in it — down with the one member this build
    /// cannot read.
    func testAnUnknownKindIsKeptWithoutLosingItsNeighbours() {
        XCTAssertEqual(
            decode(#"{"events":[{"kind":"title","value":"a"},{"kind":"weather","sky":"grey"}]}"#),
            [.title("a"), .unknown(kind: "weather")],
        )
    }

    /// Validate-then-drop, the rule every untrusted decode here follows — and this one is only as
    /// trusted as the daemon on the far end of the socket, which may be an older build.
    func testABodyThatIsNotABatchIsRefusedRatherThanGuessed() {
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[]"))
        XCTAssertNil(decode(#"{"nope":1}"#))
        XCTAssertEqual(decode(#"{"events":[]}"#), [], "an empty batch is legal, merely uninteresting")
    }

    // MARK: The translation

    func testEachEventBecomesTheMessageItsWireTypeExpects() {
        XCTAssertEqual(
            MuxChannelSession.wireMessagesForTesting([
                .title("x"),
                .bell,
                .commandRunning,
                .commandIdle(exitCode: 3, durationMS: 12),
                .cwd("/x"),
                .notification(title: "t", body: "b"),
                .progress("4;1;50"),
            ]),
            [
                .title("x"),
                .bell,
                .commandStatus(.running),
                .commandStatus(.idle(exitCode: 3, durationMS: 12)),
                .cwd("/x"),
                .notification(title: "t", body: "b"),
                .progress(state: ProgressState.inProgress.rawValue, percent: 50),
            ],
        )
    }

    /// OSC 9;4 crosses the socket UNPARSED, because the progress vocabulary belongs to
    /// `ProgressOSCParser` and a second copy of that grammar inside the byte reader is the drift
    /// this port removes. A body that will not parse is dropped — it was progress either way, and
    /// must never be promoted into a desktop notification.
    func testAProgressBodyThatWillNotParseIsDroppedRatherThanForwarded() {
        XCTAssertEqual(MuxChannelSession.wireMessagesForTesting([.progress("4;nonsense")]), [])
        XCTAssertEqual(MuxChannelSession.wireMessagesForTesting([.progress("")]), [])
    }

    /// An unknown kind is dropped from the wire, not invented into a message: it is a fact a NEWER
    /// superd knows and this build does not, and staying quiet is the only honest answer.
    func testAnUnknownKindProducesNoWireMessage() {
        XCTAssertEqual(
            MuxChannelSession.wireMessagesForTesting([.unknown(kind: "weather"), .bell]),
            [.bell],
        )
    }
}
