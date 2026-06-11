import XCTest
@testable import AislopdeskVideoClient
import AislopdeskVideoProtocol

/// PURE client-side resize debounce: a burst of mid-drag layer-size samples coalesces to
/// the SETTLED size and fires exactly once; sub-`minDelta` jitter is dropped; the epoch
/// counter increments per emitted request. Elapsed-since-last-change is passed in (the
/// ``LTREscalationTracker`` discipline) — no timer / socket touched.
final class ResizeDebounceTests: XCTestCase {

    func testStillSettlingHolds() {
        let d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        // Layer just changed (0.05s ago) — still mid-burst, do not request yet.
        XCTAssertEqual(d.decide(layerSize: VideoSize(width: 1280, height: 800), elapsedSinceLastChange: 0.05), .hold)
    }

    func testSettledAfterQuietFiresOnce() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let settled = VideoSize(width: 1280, height: 800)
        // Quiet for >= settleInterval → request the settled size.
        XCTAssertEqual(d.decide(layerSize: settled, elapsedSinceLastChange: 0.25), .request(settled))
        let epoch = d.noteRequested(settled)
        XCTAssertEqual(epoch, 1)
        // A second settled sample at the SAME size is now within minDelta (0 delta) → hold,
        // so it fires only ONCE for the settled size.
        XCTAssertEqual(d.decide(layerSize: settled, elapsedSinceLastChange: 0.5), .hold)
    }

    func testBurstCoalescesToSettledSize() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        // Simulate a live drag: many intermediate sizes arrive while NOT yet quiet → all hold.
        let intermediates = [
            VideoSize(width: 900, height: 600),
            VideoSize(width: 1000, height: 650),
            VideoSize(width: 1100, height: 700),
            VideoSize(width: 1200, height: 760),
        ]
        for size in intermediates {
            XCTAssertEqual(d.decide(layerSize: size, elapsedSinceLastChange: 0.03), .hold,
                           "mid-burst sample \(size) must hold (not yet settled)")
        }
        // The drag ends; the LAST size has now been quiet >= settleInterval → one request,
        // for the SETTLED (final) size only — the intermediates never fired.
        let settled = VideoSize(width: 1280, height: 800)
        XCTAssertEqual(d.decide(layerSize: settled, elapsedSinceLastChange: 0.3), .request(settled))
        XCTAssertEqual(d.noteRequested(settled), 1, "the whole burst produced exactly one request → epoch 1")
    }

    func testSubMinDeltaDropped() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let first = VideoSize(width: 1280, height: 800)
        XCTAssertEqual(d.decide(layerSize: first, elapsedSinceLastChange: 0.3), .request(first))
        d.noteRequested(first)

        // A settled size within minDelta on BOTH axes (a 4px wobble) is jitter → hold.
        let jitter = VideoSize(width: 1284, height: 803)
        XCTAssertEqual(d.decide(layerSize: jitter, elapsedSinceLastChange: 0.3), .hold,
                       "a < minDelta change on every axis is dropped")
    }

    func testChangeOnSingleAxisExceedingMinDeltaFires() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let first = VideoSize(width: 1280, height: 800)
        XCTAssertEqual(d.decide(layerSize: first, elapsedSinceLastChange: 0.3), .request(first))
        d.noteRequested(first)

        // Width unchanged but height jumps by >= minDelta → it IS a meaningful change.
        let taller = VideoSize(width: 1281, height: 900)
        XCTAssertEqual(d.decide(layerSize: taller, elapsedSinceLastChange: 0.3), .request(taller))
    }

    func testEpochIncrementsPerEmittedRequest() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        XCTAssertEqual(d.lastEpoch, 0, "no request emitted yet")
        XCTAssertEqual(d.noteRequested(VideoSize(width: 1280, height: 800)), 1)
        XCTAssertEqual(d.noteRequested(VideoSize(width: 1920, height: 1080)), 2)
        XCTAssertEqual(d.noteRequested(VideoSize(width: 3840, height: 2160)), 3)
        XCTAssertEqual(d.lastEpoch, 3)
        XCTAssertEqual(d.lastRequested, VideoSize(width: 3840, height: 2160))
    }

    func testDecideIsPureDoesNotMutate() {
        let d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let before = d
        _ = d.decide(layerSize: VideoSize(width: 1280, height: 800), elapsedSinceLastChange: 0.3)
        XCTAssertEqual(d, before, "decide() is a pure query — only noteRequested() mutates")
    }

    // MARK: 1:1 pane snap (noteAdopted)

    func testNoteAdoptedRebasesWithoutMintingAnEpoch() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let snapped = VideoSize(width: 1331, height: 829)
        d.noteAdopted(snapped)
        XCTAssertEqual(d.lastEpoch, 0, "a client-side snap sends nothing — no epoch minted")
        XCTAssertEqual(d.lastRequested, snapped, "the snap becomes the jitter baseline")
        // The snap-induced layout pass settles AT the adopted size → zero delta → hold: the
        // snap never echoes a resizeRequest back to the host (the feedback-loop guard).
        XCTAssertEqual(d.decide(layerSize: snapped, elapsedSinceLastChange: 0.3), .hold)
    }

    func testNoteAdoptedStopsTheFirstSettleAlwaysFiringRule() {
        // With a nil baseline the FIRST settled size always fires (changedEnough treats nil as
        // changed). After a snap rebases the baseline, an identical settled size must NOT fire —
        // otherwise every pane-follow connect would still AX-resize the host window once.
        let fresh = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let size = VideoSize(width: 1331, height: 829)
        XCTAssertEqual(fresh.decide(layerSize: size, elapsedSinceLastChange: 0.3), .request(size),
                       "precondition: a nil baseline fires on the first settle")
        var adopted = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        adopted.noteAdopted(size)
        XCTAssertEqual(adopted.decide(layerSize: size, elapsedSinceLastChange: 0.3), .hold)
    }

    func testUserDragAfterAdoptionStillRequests() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        d.noteAdopted(VideoSize(width: 1331, height: 829))
        // A real user drag (≥ minDelta from the adopted baseline) settles → host-follow resumes.
        let dragged = VideoSize(width: 1500, height: 900)
        XCTAssertEqual(d.decide(layerSize: dragged, elapsedSinceLastChange: 0.3), .request(dragged))
        XCTAssertEqual(d.noteRequested(dragged), 1, "the first WIRE request still carries epoch 1")
    }

    func testTwoSettledSizesAcrossSeparateDragsEachFire() {
        var d = ResizeDebounce(minDelta: 8, settleInterval: 0.2)
        let a = VideoSize(width: 1280, height: 800)
        XCTAssertEqual(d.decide(layerSize: a, elapsedSinceLastChange: 0.25), .request(a))
        XCTAssertEqual(d.noteRequested(a), 1)

        // A second, distinct drag settles on a clearly different size → a fresh request + epoch.
        let b = VideoSize(width: 1920, height: 1080)
        XCTAssertEqual(d.decide(layerSize: b, elapsedSinceLastChange: 0.25), .request(b))
        XCTAssertEqual(d.noteRequested(b), 2)
    }
}
