import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Ring truncation vs alt-screen segments, end to end: when the 64 MiB scrollback ring's cut
/// point lands INSIDE an open alt-screen segment, the cold-reattach replay must NOT pour the
/// segment's interior onto the main screen (the "scrollback flood" hole). The eviction-side
/// repair (``AltScreenCutScanner``) re-opens the beheaded segment so the full replay transform
/// (``ScrollbackReplayTransform``) can pair — and drop — it like any closed segment.
final class ScrollbackRingTruncationTests: XCTestCase {
    private let opener = Data("\u{1B}[?1049h".utf8)
    private let closer = Data("\u{1B}[?1049l".utf8)

    private func coldReplayJoined(_ buf: ReplayBuffer) -> Data {
        var joined = Data()
        for message in buf.replay(after: 0) {
            if case let .output(_, bytes) = message { joined.append(bytes) }
        }
        return joined
    }

    private func makeBuffer(cap: Int) throws -> ReplayBuffer {
        let transform = try XCTUnwrap(ScrollbackReplayTransform.make(
            environment: [:], reassertInputModes: true,
        ))
        return ReplayBuffer(scrollbackBytes: cap, scrollbackDistiller: transform)
    }

    /// The segment CLOSED before reattach (Claude exited): with the cut repaired, the whole
    /// truncated segment pairs up and is dropped — its interior must never reach the client.
    func testTruncatedThenClosedSegmentInteriorDoesNotLeakToMainScreen() throws {
        var buf = try makeBuffer(cap: 64)
        _ = buf.append(bytes: Data("old-history\n".utf8)) // 12B — evicted
        _ = buf.append(bytes: opener + Data("ALT-INTERIOR-ONE\n".utf8)) // 25B — evicted (mid-segment cut)
        _ = buf.append(bytes: Data("ALT-INTERIOR-TWO-no-nl".utf8)) // 22B — survives
        let s4 = buf.append(bytes: closer + Data("\r\nmain-after\r\n".utf8)) // 22B — survives
        _ = buf.append(bytes: Data("prompt$ ".utf8)) // un-acked live tail
        buf.ack(upTo: s4) // ring 81B > 64 → evicts the first two entries, cut inside the segment

        let joined = coldReplayJoined(buf)
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: joined, as: UTF8.self)
        XCTAssertFalse(
            text.contains("ALT-INTERIOR"),
            "a truncated-then-closed alt segment must be dropped whole, not replayed onto the main screen",
        )
        XCTAssertTrue(text.contains("main-after"), "post-segment main-screen output must survive")
        XCTAssertTrue(text.contains("prompt$"), "the un-acked live tail must survive")
    }

    /// The segment is STILL OPEN at reattach (the live TUI): the replay must enter the alt
    /// screen BEFORE the surviving interior, so the churn lands where it belongs.
    func testTruncatedStillOpenSegmentReplaysBehindAltScreenEnter() throws {
        var buf = try makeBuffer(cap: 64)
        _ = buf.append(bytes: Data("old-history\n".utf8)) // 12B — evicted
        _ = buf.append(bytes: opener + Data("ALT-FRAME-ONE-padding-x\n".utf8)) // 32B — evicted
        let s3 = buf.append(bytes: Data("ALT-FRAME-TWO-no-nl".utf8)) // 19B — survives
        _ = buf.append(bytes: Data("ALT-LIVE".utf8)) // un-acked live tail, still inside the TUI
        buf.ack(upTo: s3) // ring 63B ≤ 64… force the cut with one more acked frame below

        let s4 = buf.append(bytes: Data("ALT-FRAME-THREE-no-nl".utf8)) // 21B
        buf.ack(upTo: s4) // ring 84B > 64 → evicts through the opener — cut inside the OPEN segment

        let joined = coldReplayJoined(buf)
        guard let interiorRange = joined.firstRange(of: Data("ALT-FRAME".utf8)) else {
            XCTFail("surviving interior must be present in the cold replay")
            return
        }
        XCTAssertNotNil(
            joined[..<interiorRange.lowerBound].firstRange(of: opener),
            "the replay must re-enter the alt screen before any surviving segment interior",
        )
    }
}
