import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE tests for the FIX #2 / #4 / #6 additions to ``VideoMuxRouter``:
///   - the retired-set bound (cap 512, prune to within 256 of the wrap-aware high-water mark), and
///   - the bootstrap decider (`bootstrapAction`) that re-admits a retired/unadmitted lane ONLY on a
///     real `hello` control datagram, and never stamps a flow for a stray non-hello control datagram.
/// No socket / no `NWListener` / no SCStream — exactly the discipline of `VideoMuxRouterTests`.
final class VideoMuxRouterReadmitTests: XCTestCase {
    // MARK: - FIX #4: retired-set cap / prune

    func testRetiredSetIsBoundedAndPrunesFarBelowHighWaterMark() {
        // Monotonically retire well past the cap; the OLDEST (far-below) ids must be PRUNED out of
        // `retired` — they fall back to `.rejectUnadmitted` (a clean drop for an unknown lane) — while
        // ids within the prune window of the high-water mark stay `.dropRetired`.
        var router = VideoMuxRouter()
        let count: UInt32 = 700 // > retiredCap (512)
        for id in 1...count { router.retire(id) }

        // High-water mark is `count` (700). The prune keeps ids within `retiredPruneWindow` (256) of
        // it; anything more than 256 below is dropped from the set.
        let high = count
        let prunedFar: UInt32 = 1 // 699 below high → far outside the window → pruned
        XCTAssertEqual(
            router.route(channelID: prunedFar, channel: .video, bytesCount: 100),
            .rejectUnadmitted,
            "an id far below the high-water mark is pruned from `retired` (cannot have an in-flight datagram)",
        )

        let keptNear: UInt32 = high - 10 // within 256 of high → retained
        XCTAssertEqual(
            router.route(channelID: keptNear, channel: .video, bytesCount: 100),
            .dropRetired,
            "an id within the prune window stays retired (its in-flight bytes still drop)",
        )
    }

    func testRetiredSetDoesNotGrowUnbounded() {
        // After retiring far more than the cap, OLD ids are pruned (they fall back to
        // `.rejectUnadmitted`) while RECENT ids near the high-water mark are retained. The prune only
        // fires when the set exceeds `retiredCap`, so the retained window is bounded by ~cap, never
        // monotonically growing for the daemon lifetime. (The set is private — observed via behavior.)
        var router = VideoMuxRouter()
        let high: UInt32 = 5000
        for id in 1...high { router.retire(id) }

        // The most-recent ids (within the prune window of the high-water mark) are always retained.
        XCTAssertEqual(router.route(channelID: high, channel: .video, bytesCount: 100), .dropRetired)
        XCTAssertEqual(router.route(channelID: high - 1, channel: .video, bytesCount: 100), .dropRetired)

        // An id thousands below the high-water mark cannot still have an in-flight datagram and must
        // have been pruned — it drops cleanly as an unknown lane, NOT as a retired one.
        XCTAssertEqual(
            router.route(channelID: 1, channel: .video, bytesCount: 100),
            .rejectUnadmitted,
            "ancient retired ids are pruned; the set does not grow unbounded",
        )
        XCTAssertEqual(
            router.route(channelID: high / 2, channel: .video, bytesCount: 100),
            .rejectUnadmitted,
            "an id far below the high-water mark is pruned",
        )
    }

    // MARK: - FIX #2 / #6: bootstrap re-admit decider

    func testRetiredLaneReadmitsOnlyOnHello() {
        // FIX #2: a retired channelID re-admits (bootstrapDeliver) on a hello control datagram, but a
        // non-hello control datagram for it still drops (generation safety), and any non-control too.
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .dropRetired, channel: .control, payloadIsHello: true),
            .bootstrapDeliver, "a retired lane re-admits on an explicit hello",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .dropRetired, channel: .control, payloadIsHello: false),
            .dropNoStamp, "a retired lane drops a non-hello control datagram (stale old-gen)",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .dropRetired, channel: .video, payloadIsHello: false),
            .dropNoStamp, "a retired lane drops in-flight video (reconnect-generation safety)",
        )
    }

    func testUnadmittedLaneBootstrapsOnlyOnHello() {
        // FIX #6: an unadmitted lane bootstraps (and the transport stamps its reply flow) ONLY on a
        // hello control datagram; a stray non-hello control datagram drops WITHOUT a stamp.
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .rejectUnadmitted, channel: .control, payloadIsHello: true),
            .bootstrapDeliver, "the first hello bootstraps an unadmitted lane",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .rejectUnadmitted, channel: .control, payloadIsHello: false),
            .dropNoStamp, "a stray non-hello control datagram drops without remembering its flow",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .rejectUnadmitted, channel: .input, payloadIsHello: false),
            .dropNoStamp, "a stray non-control datagram for an unknown lane drops",
        )
    }

    func testListRequestBootstrapsLikeHelloOnControlOnly() {
        // docs/31 picker: a window-LIST request bootstraps (deliver + stamp the reply flow) like a hello
        // on the control channel for an unadmitted OR retired lane — so the daemon can answer it (without
        // minting a session). It must NOT bootstrap off a non-control channel, nor while draining.
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(
                for: .rejectUnadmitted,
                channel: .control,
                payloadIsHello: false,
                payloadIsListRequest: true,
            ),
            .bootstrapDeliver, "a listWindows request bootstraps an unadmitted lane (session-less reply)",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(
                for: .dropRetired,
                channel: .control,
                payloadIsHello: false,
                payloadIsListRequest: true,
            ),
            .bootstrapDeliver, "a listWindows request bootstraps a retired lane too (cross-process reuse)",
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(
                for: .rejectUnadmitted,
                channel: .video,
                payloadIsHello: false,
                payloadIsListRequest: true,
            ),
            .dropNoStamp, "a list request off the control channel drops (only .control bootstraps)",
        )
        let listWhileDraining = VideoMuxRouter.Decision.dropDraining
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(
                for: listWhileDraining,
                channel: .control,
                payloadIsHello: false,
                payloadIsListRequest: true,
            ),
            .dropNoStamp, "a list request racing a teardown drops like a hello does",
        )
    }

    func testRoutedAndEmptyDecisionsNeverBootstrap() {
        // `.route` is handled on the live path; an empty `.drop` never bootstraps regardless of input.
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: .route(channelID: 5), channel: .control, payloadIsHello: true),
            .dropNoStamp,
        )
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(
                for: .drop(reason: "empty datagram"),
                channel: .control,
                payloadIsHello: true,
            ),
            .dropNoStamp,
        )
    }

    // MARK: - FIX #4b: draining state (reaper holds the lane through teardown)

    func testDrainingLaneDropsEverythingIncludingHello() {
        // While a lane is draining (reaper stopping its session), EVERY datagram drops — a hello must
        // NOT re-admit yet (that would re-mint onto a dying session / the late endDrain would kill it).
        var router = VideoMuxRouter()
        router.admit(1)
        router.beginDrain(1)
        XCTAssertTrue(router.isDraining(1))
        XCTAssertFalse(router.isAdmitted(1), "beginDrain stops routing the lane")
        XCTAssertEqual(router.route(channelID: 1, channel: .video, bytesCount: 100), .dropDraining)
        let helloWhileDraining = router.route(channelID: 1, channel: .control, bytesCount: 8)
        XCTAssertEqual(helloWhileDraining, .dropDraining)
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: helloWhileDraining, channel: .control, payloadIsHello: true),
            .dropNoStamp, "a hello racing the teardown drops — no false accept, no premature re-mint",
        )
    }

    func testEndDrainTransitionsToRetiredThenHelloReadmits() {
        // After the session is stopped, endDrain moves draining → retired, where FIX #2's hello
        // re-admit applies — so the reconnecting client's NEXT hello cleanly re-mints.
        var router = VideoMuxRouter()
        router.admit(2)
        router.beginDrain(2)
        router.endDrain(2)
        XCTAssertFalse(router.isDraining(2))
        XCTAssertEqual(
            router.route(channelID: 2, channel: .video, bytesCount: 100),
            .dropRetired,
            "after endDrain the lane is retired (stale old-gen still drops)",
        )
        let hello = router.route(channelID: 2, channel: .control, bytesCount: 8)
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: hello, channel: .control, payloadIsHello: true),
            .bootstrapDeliver, "a fresh hello after endDrain re-admits the lane",
        )
        router.admit(2)
        XCTAssertEqual(router.route(channelID: 2, channel: .video, bytesCount: 100), .route(channelID: 2))
    }

    func testHelloReadmitClearsRetiredMarkEndToEnd() {
        // The full FIX #2 chain at the router level: retire an id → it `.dropRetired`s → the daemon's
        // mint path calls `admit` (driven by the bootstrapDeliver), which clears the retired mark →
        // the SAME id now routes again (cross-process reuse after a client restart).
        var router = VideoMuxRouter()
        router.admit(1)
        router.retire(1)
        XCTAssertEqual(router.route(channelID: 1, channel: .video, bytesCount: 100), .dropRetired)

        // A hello on the retired lane → bootstrapDeliver → registry mints → session.start admits.
        let helloDecision = router.route(channelID: 1, channel: .control, bytesCount: 8)
        XCTAssertEqual(helloDecision, .dropRetired, "the router still reports retired until admit runs")
        XCTAssertEqual(
            VideoMuxRouter.bootstrapAction(for: helloDecision, channel: .control, payloadIsHello: true),
            .bootstrapDeliver,
        )
        router.admit(1) // what the mint path does on session.start (VideoMuxChannelTransport.start)
        XCTAssertEqual(
            router.route(channelID: 1, channel: .video, bytesCount: 100),
            .route(channelID: 1),
            "after re-admission the reused id routes again — reconnect unblocked",
        )
    }
}
