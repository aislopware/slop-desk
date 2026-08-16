import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// A flag two tasks write and read across a suspension, so the ordering assertion below can be
/// stated as a fact rather than a timeout.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Mirrors the SESSION ACTOR's two arms that contend in the defect: `pumpFrame` is the
/// encoded-frame pump (post-fix `onEncodedFrame` shape: AWAIT the ``PacketizeLane`` — the
/// suspension point under test), and `inject` is the hop a keystroke rides from the inbound
/// consumer to `CGEventPost`. The keystroke-to-echo requirement: `inject` must be able to
/// complete while a large frame is mid-packetize. (The pre-fix shape — packetize INLINE on this
/// actor — was run first and FAILED this suite's mid-packetize test by starving `inject`.)
private actor SessionActorStandIn {
    private let lane: PacketizeLane
    private(set) var injected = 0

    init(lane: PacketizeLane) {
        self.lane = lane
    }

    /// The fixed `onEncodedFrame` shape: hand the frame to the lane and suspend. `entered` is
    /// signalled from ON this actor immediately before the hop, so a waiter that sees it knows the
    /// pump is committed — inline work would begin here too, which is what makes the ordering
    /// assertion discriminate the two shapes rather than merely time them.
    func pumpFrame(
        _ avcc: Data,
        keyframe: Bool = true,
        entered: DispatchSemaphore? = nil,
    ) async -> PacketizeLane.PacketizedFrame {
        entered?.signal()
        return await lane.packetize(
            frame: avcc,
            keyframe: keyframe,
            crisp: false,
            hostSendTsMillis: 0,
            fecTier: 0,
            isLTR: false,
            ackedAnchored: false,
            interleave: false,
        )
    }

    func inject() {
        injected += 1
    }
}

final class PacketizeLaneTests: XCTestCase {
    /// The keystroke-latency contract: an input-injection hop onto the session actor completes
    /// while a large frame is mid-packetize.
    ///
    /// What pins it is ORDER, not a timeout: `inject` must finish BEFORE the pump does. Under the
    /// pre-fix shape — packetize inline on the session actor — that is impossible however long the
    /// test waits, because the actor cannot admit `inject` until the whole packetize returns. The
    /// frame is deliberately enormous so the window the two are ordered inside is milliseconds of
    /// real work against a keystroke hop that costs microseconds.
    func testInputCompletesWhileLargeFrameMidPacketize() async {
        let standIn = SessionActorStandIn(
            lane: PacketizeLane(fec: XORParityFEC(groupSize: 5, parityCount: 1)),
        )
        let frame = Data(repeating: 0xAB, count: 24 * 1024 * 1024) // ~21k data fragments + parity
        let entered = DispatchSemaphore(value: 0)
        let pumped = Latch()
        let pump = Task { () -> PacketizeLane.PacketizedFrame in
            let out = await standIn.pumpFrame(frame, entered: entered)
            pumped.set()
            return out
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the pump never started")
        // A keystroke arriving NOW must be injectable: the actor must be free mid-packetize.
        let injectDone = expectation(description: "inject completed while packetize mid-flight")
        Task {
            await standIn.inject()
            injectDone.fulfill()
        }
        await fulfillment(of: [injectDone], timeout: 5)
        XCTAssertFalse(pumped.isSet, "inject was admitted only after the frame finished packetizing")
        let packetized = await pump.value
        XCTAssertFalse(packetized.outgoings.isEmpty, "the frame still packetizes fully")
        let injected = await standIn.injected
        XCTAssertEqual(injected, 1)
    }

    /// Production ordering shape: the single encoded-frame consumer awaits one frame at a time,
    /// so frameIDs come back 0,1,2,… monotonic AND every wire datagram of a frame carries the
    /// frameID the lane returned for it (no frame dropped, order preserved end-to-end).
    func testFrameIDsMonotonicUnderSequentialAwaits() async {
        let standIn = SessionActorStandIn(lane: PacketizeLane(fec: XORParityFEC(groupSize: 5, parityCount: 1)))
        for expected in 0..<UInt32(20) {
            let packetized = await standIn.pumpFrame(Data(repeating: UInt8(expected), count: 3000))
            XCTAssertEqual(packetized.frameID, expected, "frameIDs must advance one per frame, in order")
            XCTAssertFalse(packetized.outgoings.isEmpty)
            for outgoing in packetized.outgoings {
                XCTAssertEqual(outgoing.channel, .video)
                let fragment = try? FrameFragment.decode(outgoing.bytes)
                XCTAssertEqual(
                    fragment?.header.frameID, expected,
                    "every wire datagram carries the frameID the lane returned",
                )
            }
        }
    }

    /// Actor serialization: even under CONCURRENT submissions (never the production shape, but the
    /// counters must not corrupt if a second caller ever appears) every call gets a UNIQUE frameID,
    /// the set is exactly 0..<N (no drops, no duplicates), and each frame's datagrams are
    /// internally consistent with its returned frameID.
    func testConcurrentSubmissionsAssignUniqueConsistentFrameIDs() async {
        let lane = PacketizeLane(fec: XORParityFEC(groupSize: 5, parityCount: 1))
        let results = await withTaskGroup(of: PacketizeLane.PacketizedFrame.self) { group in
            for i in 0..<16 {
                group.addTask {
                    await lane.packetize(
                        frame: Data(repeating: UInt8(i), count: 5000),
                        keyframe: false,
                        crisp: false,
                        hostSendTsMillis: 0,
                        fecTier: 0,
                        isLTR: false,
                        ackedAnchored: false,
                        interleave: true,
                    )
                }
            }
            var collected: [PacketizeLane.PacketizedFrame] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(Set(results.map(\.frameID)), Set(0..<UInt32(16)), "no duplicate/skipped frameIDs")
        for packetized in results {
            for outgoing in packetized.outgoings {
                let fragment = try? FrameFragment.decode(outgoing.bytes)
                XCTAssertEqual(fragment?.header.frameID, packetized.frameID)
            }
        }
    }

    /// One packetize-input shape for the byte-identity pin (a struct, not a tuple — lint caps
    /// tuples at 4 members).
    private struct WireCase {
        var frame: Data
        var keyframe = false
        var crisp = false
        var sendTs: UInt32 = 0
        var tier: UInt8 = 0
        var isLTR = false
        var ackedAnchored = false
        var interleave = false
    }

    /// Byte-identity pin: the lane moves WHERE the work runs, never WHAT it computes. For the same
    /// inputs (incl. the production m==1 ≡ XOR FEC, tiers, LTR bits, and the interleave permutation)
    /// the lane's wire bytes equal the direct `packetizeRaw` + `scheduleFrameRaw` composition
    /// byte-for-byte, in the same order, on the same channel.
    func testLaneWireBytesByteIdenticalToDirectPacketizer() async {
        let lane = PacketizeLane(fec: XORParityFEC(groupSize: 5, parityCount: 1))
        let reference = VideoPacketizer(fec: XORParityFEC(groupSize: 5, parityCount: 1))
        let scheduler = VideoSendScheduler()
        let cases: [WireCase] = [
            WireCase(
                frame: Data(repeating: 0x11, count: 9500),
                keyframe: true,
                sendTs: 1234,
                interleave: true,
            ),
            WireCase(frame: Data(repeating: 0x22, count: 300), ackedAnchored: true),
            WireCase(
                frame: Data(repeating: 0x33, count: 25000),
                crisp: true,
                sendTs: 77,
                tier: 2,
                isLTR: true,
                interleave: true,
            ),
            WireCase(frame: Data(), keyframe: true, sendTs: 5), // zero-byte frame still = 1 fragment
        ]
        for wireCase in cases {
            let viaLane = await lane.packetize(
                frame: wireCase.frame,
                keyframe: wireCase.keyframe,
                crisp: wireCase.crisp,
                hostSendTsMillis: wireCase.sendTs,
                fecTier: wireCase.tier,
                isLTR: wireCase.isLTR,
                ackedAnchored: wireCase.ackedAnchored,
                interleave: wireCase.interleave,
            )
            let direct = scheduler.scheduleFrameRaw(reference.packetizeRaw(
                frame: wireCase.frame,
                keyframe: wireCase.keyframe,
                crisp: wireCase.crisp,
                hostSendTsMillis: wireCase.sendTs,
                fecTier: wireCase.tier,
                isLTR: wireCase.isLTR,
                ackedAnchored: wireCase.ackedAnchored,
                interleave: wireCase.interleave,
            ))
            XCTAssertEqual(viaLane.outgoings, direct, "wire bytes must be byte-identical to the inline path")
        }
    }
}
