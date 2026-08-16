#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import XCTest
@testable import SlopDeskVideoClient

/// Pins the one-shot discovery both remote-window and display lists run over a transient lane: the
/// video path is fire-and-forget UDP with no request-and-response machinery, so the discovery builds
/// its own out of a resend schedule and a box that resolves exactly once.
///
/// The schedule is `slopdesk-video`'s and pinned there; what these pin is the half that lives here —
/// the box, whose single `CheckedContinuation` must be resumed once and only once (twice traps, never
/// leaks the picker) — and that this side asks the far side for the schedule rather than deriving one.
final class VideoWindowDiscoveryTests: XCTestCase {
    /// The request goes out once per interval until the deadline, and one try still happens when the
    /// whole timeout is shorter than a single interval.
    func testTheScheduleIsTheFarSidesAndOneTryStillHappens() {
        XCTAssertEqual(
            VideoWindowDiscovery.sendOffsets(timeout: 3, retryInterval: 0.5),
            [0, 0.5, 1.0, 1.5, 2.0, 2.5],
        )
        XCTAssertEqual(VideoWindowDiscovery.sendOffsets(timeout: 0.4, retryInterval: 0.5), [0])
    }

    /// An interval of zero or less is not a schedule but a SPIN — the loop it would drive sends as
    /// fast as the CPU allows until the deadline. No offsets means no sends, and the discovery
    /// resolves empty instead.
    func testAnIntervalThatWouldSpinPlansNothing() {
        XCTAssertTrue(VideoWindowDiscovery.sendOffsets(timeout: 3, retryInterval: 0).isEmpty)
        XCTAssertTrue(VideoWindowDiscovery.sendOffsets(timeout: 3, retryInterval: -1).isEmpty)
        XCTAssertTrue(VideoWindowDiscovery.sendOffsets(timeout: 0, retryInterval: 0.5).isEmpty)
        XCTAssertTrue(VideoWindowDiscovery.sendOffsets(timeout: .nan, retryInterval: 0.5).isEmpty)
    }

    /// The first reply resolves the waiter; the resend's echo must not resolve it a second time nor
    /// replace the answer it already gave.
    func testADuplicateReplyFromAResendIsIgnored() async {
        let box = ReplyBox<Int>()
        XCTAssertFalse(box.hasReply)
        box.deliver([4])
        XCTAssertTrue(box.hasReply, "which is the cue to stop resending")
        box.deliver([9])
        let result = await box.firstReply()
        XCTAssertEqual(result, [4])
    }

    /// A host too old to understand the request never replies, and the picker must fall back to
    /// manual entry rather than hang: the timeout resolves the waiter with nothing.
    func testAHostTooOldToAnswerResolvesThePickerInsteadOfHangingIt() async {
        let box = ReplyBox<Int>()
        box.finish()
        let result = await box.firstReply()
        XCTAssertNil(result)
    }

    /// The waiter is resolved EXACTLY once however the two edges race — a second resume traps, so
    /// `finish()` after a reply, and a reply after `finish()`, must both be no-ops.
    func testTheWaiterResolvesExactlyOnceHoweverTheEdgesRace() async {
        let delivered = ReplyBox<Int>()
        delivered.deliver([1])
        delivered.finish()
        let first = await delivered.firstReply()
        XCTAssertEqual(first, [1], "the timeout cannot overwrite an answer that landed")

        let finished = ReplyBox<Int>()
        finished.finish()
        finished.deliver([2])
        let second = await finished.firstReply()
        XCTAssertNil(second, "a reply after the deadline cannot resume a waiter twice")
    }

    /// A waiter that arrives after the answer resolves immediately rather than parking forever.
    func testAWaiterThatArrivesAfterTheAnswerDoesNotPark() async {
        let box = ReplyBox<Int>()
        box.deliver([7])
        let result = await box.firstReply()
        XCTAssertEqual(result, [7])
    }
}
#endif
