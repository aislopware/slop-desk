#if canImport(VideoToolbox) && canImport(Metal) && canImport(QuartzCore)
import XCTest
@testable import AislopdeskVideoClient
import AislopdeskVideoProtocol

/// BUG-H regression: the LTR→IDR escalation must fire 2·RTT after the FIRST outstanding
/// recovery request, not be perpetually pushed out by each new per-frame loss.
///
/// The old `AislopdeskVideoClientSession` reset its `lastRecoveryRequestTime` on EVERY
/// dropped frame (once per loss). Under sustained loss the 2·RTT clock therefore never
/// elapsed and the guaranteed-recovery forced IDR never fired — the stream starved.
/// `LTREscalationTracker` arms the clock on the FIRST request only and never rearms it
/// on subsequent losses, so the escalation deadline measured from the first request can
/// actually be reached. Pure (host time passed in) — no socket / decoder.
final class LTREscalationTrackerTests: XCTestCase {
    private let policy = RecoveryPolicy(idrTimeoutRTTMultiple: 2.0)
    private let rtt: TimeInterval = 0.05 // 50 ms; 2·RTT = 100 ms

    func testNoEscalationBeforeAnyRequest() {
        let tracker = LTREscalationTracker()
        XCTAssertFalse(tracker.hasOutstandingRequest)
        XCTAssertFalse(tracker.shouldEscalate(now: 100, rtt: rtt, policy: policy))
    }

    /// The core fix: repeated losses each send a recovery request, but the escalation
    /// clock stays pinned to the FIRST request — so 2·RTT after that first request the
    /// escalation fires, instead of being reset to "now" by the latest loss.
    func testEscalationFiresTwoRTTAfterFirstRequestDespiteRepeatedLosses() {
        var tracker = LTREscalationTracker()

        // First loss at t=0 arms the clock.
        tracker.noteRequestSent(now: 0)
        XCTAssertTrue(tracker.hasOutstandingRequest)
        XCTAssertEqual(tracker.firstRequestTime, 0)

        // Sustained loss: a fresh recovery request every 10 ms. The OLD code reset the
        // clock to each of these, so the elapsed-since-request never reached 2·RTT.
        for t in stride(from: 0.01, through: 0.09, by: 0.01) {
            tracker.noteRequestSent(now: t)
            // The clock must NOT move off the first request.
            XCTAssertEqual(tracker.firstRequestTime, 0)
            // Still inside the 2·RTT (100 ms) window measured from t=0 — no escalation.
            XCTAssertFalse(tracker.shouldEscalate(now: t, rtt: rtt, policy: policy),
                           "must not escalate at t=\(t) (< 2·RTT from first request)")
        }

        // At exactly 2·RTT from the FIRST request the escalation fires, even though the
        // most recent loss was just 10 ms ago. This is the behaviour the bug suppressed.
        XCTAssertTrue(tracker.shouldEscalate(now: 0.10, rtt: rtt, policy: policy))
    }

    func testKeyframeDecodeClearsTheEpisodeAndRestartsTheClock() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0)
        XCTAssertTrue(tracker.shouldEscalate(now: 0.10, rtt: rtt, policy: policy))

        // A keyframe decoded → episode over, clock disarmed.
        tracker.keyframeDecoded()
        XCTAssertFalse(tracker.hasOutstandingRequest)
        XCTAssertNil(tracker.firstRequestTime)
        XCTAssertFalse(tracker.shouldEscalate(now: 0.50, rtt: rtt, policy: policy))

        // A new loss after recovery starts a FRESH 2·RTT window from its own first
        // request (t=1.0), not from the previous episode.
        tracker.noteRequestSent(now: 1.0)
        XCTAssertEqual(tracker.firstRequestTime, 1.0)
        XCTAssertFalse(tracker.shouldEscalate(now: 1.05, rtt: rtt, policy: policy)) // 1·RTT
        XCTAssertTrue(tracker.shouldEscalate(now: 1.10, rtt: rtt, policy: policy))  // 2·RTT
    }

    /// A forced IDR sent while recovery is already outstanding (the actor's
    /// `requestIDR()` also calls `noteRequestSent`) must keep the original first-request
    /// time — escalation timing is anchored to entering recovery, not to the IDR send.
    func testForcedIDRRequestDoesNotMoveTheClock() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0)      // first LTR request
        tracker.noteRequestSent(now: 0.10)   // escalation → forced IDR request
        XCTAssertEqual(tracker.firstRequestTime, 0)
    }

    // MARK: F7 — coalesce post-escalation IDR requests

    /// After a forced-IDR escalation FIRES, the drain loop calls `noteEscalated(now:)`
    /// to re-anchor the clock. A second escalation must then NOT fire again until another
    /// full 2·RTT has elapsed — otherwise every subsequent dropped frame in the same loss
    /// episode resends a redundant `requestIDR` (F7).
    func testEscalationCoalescesUntilAnotherTwoRTTElapses() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0)                                       // first LTR request, t=0
        XCTAssertTrue(tracker.shouldEscalate(now: 0.10, rtt: rtt, policy: policy))  // 2·RTT → escalate

        // The drain loop re-anchors at the escalation time.
        tracker.noteEscalated(now: 0.10)
        XCTAssertEqual(tracker.firstRequestTime, 0.10)

        // The very next dropped frame (10 ms later) must NOT re-escalate — the OLD code
        // kept returning true here and spammed requestIDR per dropped frame.
        XCTAssertFalse(tracker.shouldEscalate(now: 0.11, rtt: rtt, policy: policy))
        XCTAssertFalse(tracker.shouldEscalate(now: 0.19, rtt: rtt, policy: policy)) // <2·RTT from re-anchor

        // Only after another full 2·RTT from the re-anchor (t=0.10 + 0.10 = 0.20) may a
        // second escalation fire.
        XCTAssertTrue(tracker.shouldEscalate(now: 0.20, rtt: rtt, policy: policy))
    }

    /// F7 must NOT break BUG-H: an ORDINARY recovery request (`noteRequestSent`) still
    /// does not move the first-request clock, so the FIRST escalation under sustained
    /// loss still fires 2·RTT after the first request.
    func testOrdinaryLossStillEscalatesTheFirstTime() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0)
        // Repeated ordinary requests must not push the clock (BUG-H invariant preserved).
        tracker.noteRequestSent(now: 0.03)
        tracker.noteRequestSent(now: 0.06)
        XCTAssertEqual(tracker.firstRequestTime, 0)
        XCTAssertFalse(tracker.shouldEscalate(now: 0.09, rtt: rtt, policy: policy)) // <2·RTT
        XCTAssertTrue(tracker.shouldEscalate(now: 0.10, rtt: rtt, policy: policy))  // first escalation fires
    }

    /// A keyframe decode after an escalation still ends the episode (re-anchoring does
    /// not wedge the clock armed).
    func testKeyframeAfterEscalationStillClearsEpisode() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0)
        XCTAssertTrue(tracker.shouldEscalate(now: 0.10, rtt: rtt, policy: policy))
        tracker.noteEscalated(now: 0.10)
        tracker.keyframeDecoded()
        XCTAssertFalse(tracker.hasOutstandingRequest)
        XCTAssertNil(tracker.firstRequestTime)
        XCTAssertFalse(tracker.shouldEscalate(now: 1.0, rtt: rtt, policy: policy))
    }

    // MARK: SELF-HEAL (2026-06-11) — a decoded P-frame newer than every loss ends the episode

    /// THE self-heal fix: the WF-8 LTR-refresh recovery frame (and every cadence refresh) is a
    /// P-frame, `keyframe=false` on the wire. The OLD tracker cleared only on a keyframe, so a
    /// recovery that SUCCEEDED via refresh still fired a spurious forced IDR 2·RTT later. A
    /// successfully-decoded frame strictly NEWER than every recorded loss must end the episode.
    func testDecodedFrameNewerThanLossHealsEpisode() {
        var tracker = LTREscalationTracker()
        tracker.noteLoss(frameID: 100)
        tracker.noteRequestSent(now: 0)
        XCTAssertTrue(tracker.hasOutstandingRequest)

        // An OLDER frame (in flight before the loss) decoding must NOT clear the episode.
        XCTAssertFalse(tracker.frameDecoded(frameID: 99))
        XCTAssertTrue(tracker.hasOutstandingRequest)
        // The lost frame itself can never decode, but boundary-equal must also not clear.
        XCTAssertFalse(tracker.frameDecoded(frameID: 100))
        XCTAssertTrue(tracker.hasOutstandingRequest)

        // The healing refresh (a P-frame newer than the loss) ends the episode — no IDR.
        XCTAssertTrue(tracker.frameDecoded(frameID: 101))
        XCTAssertFalse(tracker.hasOutstandingRequest)
        XCTAssertNil(tracker.maxLostFrameID)
        XCTAssertFalse(tracker.shouldEscalate(now: 1.0, rtt: rtt, policy: policy))
    }

    /// Multiple losses in one episode: the boundary is the NEWEST loss — a frame between two
    /// losses must not clear; only one past ALL of them may.
    func testEpisodeBoundaryIsNewestLoss() {
        var tracker = LTREscalationTracker()
        tracker.noteLoss(frameID: 100)
        tracker.noteRequestSent(now: 0)
        tracker.noteLoss(frameID: 140)
        tracker.noteRequestSent(now: 0.01)
        // Out-of-order loss reports keep the newest boundary (wrap-aware keep-newest).
        tracker.noteLoss(frameID: 120)
        XCTAssertEqual(tracker.maxLostFrameID, 140)

        XCTAssertFalse(tracker.frameDecoded(frameID: 130), "between losses — chain not proven past 140")
        XCTAssertTrue(tracker.hasOutstandingRequest)
        XCTAssertTrue(tracker.frameDecoded(frameID: 141))
        XCTAssertFalse(tracker.hasOutstandingRequest)
    }

    /// A hard-decode-failure `requestIDR()` arms the episode WITHOUT a loss frameID. Then only a
    /// keyframe may clear it (the decoder session was invalidated — only an IDR reconfigures it):
    /// `frameDecoded` must be inert when no loss was attributed.
    func testEpisodeWithoutAttributedLossClearsOnlyOnKeyframe() {
        var tracker = LTREscalationTracker()
        tracker.noteRequestSent(now: 0) // e.g. awaitingKeyframe / hard decode failure
        XCTAssertNil(tracker.maxLostFrameID)
        XCTAssertFalse(tracker.frameDecoded(frameID: 5000))
        XCTAssertTrue(tracker.hasOutstandingRequest)
        tracker.keyframeDecoded()
        XCTAssertFalse(tracker.hasOutstandingRequest)
    }

    /// frameID wrap-around: a loss near UInt32.max healed by a post-wrap frame (wrap-aware compare,
    /// same `distanceWrapped` contract as the reassembler).
    func testHealAcrossFrameIDWrap() {
        var tracker = LTREscalationTracker()
        tracker.noteLoss(frameID: UInt32.max - 1)
        tracker.noteRequestSent(now: 0)
        XCTAssertFalse(tracker.frameDecoded(frameID: UInt32.max - 2), "older across wrap must not clear")
        XCTAssertTrue(tracker.frameDecoded(frameID: 2), "post-wrap newer frame heals")
        XCTAssertFalse(tracker.hasOutstandingRequest)
    }

    /// keyframeDecoded must clear the loss boundary too, so a STALE boundary from a closed episode
    /// can never let an old-loss comparison leak into the next episode.
    func testKeyframeClearsLossBoundary() {
        var tracker = LTREscalationTracker()
        tracker.noteLoss(frameID: 100)
        tracker.noteRequestSent(now: 0)
        tracker.keyframeDecoded()
        XCTAssertNil(tracker.maxLostFrameID)
        // Next episode armed by a hard failure (no attributed loss): a successful delta decode at
        // 101 must NOT clear it via the previous episode's stale boundary.
        tracker.noteRequestSent(now: 1.0)
        XCTAssertFalse(tracker.frameDecoded(frameID: 101))
        XCTAssertTrue(tracker.hasOutstandingRequest)
    }
}
#endif
