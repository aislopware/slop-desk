import XCTest
@testable import AislopdeskVideoProtocol

/// LOAD-BEARING PROOF for the gated multi-loss Reed-Solomon FEC (`AISLOPDESK_FEC_M >= 2`).
///
/// These tests round-trip a synthetic multi-group AVCC frame through the REAL Rust-backed send path
/// (``VideoPacketizer`` built with `(k, m)`) and the REAL Rust-backed receive path
/// (``FrameReassembler`` built with the SAME `(k, m)`), with NO VideoToolbox / network — pure
/// headless byte plumbing. They prove the property that distinguishes `m >= 2` from the production
/// `m == 1` / XOR wire:
///
///  * with `m == 2`, DROPPING 2 DATA FRAGMENTS PER GROUP still recovers the frame byte-exact;
///  * an `m == 1` control on the SAME 2-loss pattern provably CANNOT recover (XOR repairs at most one
///    loss per group), and the frame is dropped;
///  * `m + 1 == 3` losses in a group exceed the budget and fail GRACEFULLY (frame dropped, no panic).
///
/// Plus the env-gate resolution (parse/clamp of `AISLOPDESK_FEC_M` / `AISLOPDESK_FEC_K`) and the
/// `m == 1` default-unchanged guarantee.
final class MultiLossFECActivationTests: XCTestCase {
    /// Deterministic per-NALU content so a recovered frame can be asserted byte-exact.
    private func makeAVCC(naluSizes: [Int]) -> Data {
        let units = naluSizes.enumerated().map { i, size in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i &* 17 &+ 7) })
        }
        return NALUnit.join(units)
    }

    /// Builds an AVCC frame whose MTU split yields EXACTLY `dataFragments` data fragments: one full-MTU
    /// NAL unit per fragment (the join adds the 4-byte AVCC length prefix, so each NAL is sized to fill
    /// a fragment payload). Asserts the resulting data-fragment count to keep the group math exact.
    private func multiGroupFrame(dataFragments: Int) -> Data {
        // One NAL unit per fragment: payload budget minus the 4-byte AVCC length prefix the join adds.
        let nalSize = VideoPacketizer.maxPayloadSize - 4
        return makeAVCC(naluSizes: Array(repeating: nalSize, count: dataFragments))
    }

    /// Packetizes `frame`, returns (data fragments in index order, parity fragments in index order).
    /// `groupSize` is the per-frame group size the packetizer must use (= `k` for `m > 1`). Tier 0.
    private func packetize(
        _ frame: Data,
        packetizer: VideoPacketizer,
    ) -> (data: [FrameFragment], parity: [FrameFragment]) {
        let frags = packetizer.packetize(frame: frame, keyframe: true)
        let data = frags.filter { !$0.header.flags.contains(.parity) }
            .sorted { $0.header.fragIndex < $1.header.fragIndex }
        let parity = frags.filter { $0.header.flags.contains(.parity) }
            .sorted { $0.header.fragIndex < $1.header.fragIndex }
        return (data, parity)
    }

    /// Feeds every survivor fragment to `reassembler` and returns the completed frame (or nil if the
    /// frame never completed). Order: all survivors, then a stale poll — the reassembler completes as
    /// soon as the last needed fragment lands.
    private func reassemble(_ survivors: [FrameFragment], into reassembler: FrameReassembler) -> ReassembledFrame? {
        var completed: ReassembledFrame?
        for f in survivors {
            if case let .completed(rf) = reassembler.ingest(f) { completed = rf }
        }
        return completed
    }

    // MARK: The core 2-loss-per-group recovery proof (m=2, k=5)

    /// m=2 / k=5: a multi-group frame with TWO data fragments dropped IN EACH GROUP still reassembles
    /// byte-exact — the property XOR/`m == 1` cannot deliver. Round-trips through the real packetizer
    /// (built `(5, 2)`) and the real reassembler (built `(5, 2)`).
    func testTwoLossesPerGroupRecoverWithM2() throws {
        let k = 5
        let m = 2
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        // 10 data fragments ⇒ exactly two full groups of k=5.
        let frame = multiGroupFrame(dataFragments: 2 * k)
        let (data, parity) = packetize(frame, packetizer: packetizer)
        XCTAssertEqual(data.count, 2 * k, "frame should split into exactly 2 groups of k")
        XCTAssertEqual(parity.count, 2 * m, "2 groups × m=2 parity shards")

        // Drop 2 DISTINCT data fragments in EACH group (a 2-loss burst per group).
        let dropIndices: Set<UInt16> = [0, 1, /* group 0 */ 5, 7 /* group 1 */ ]
        let survivors = data.filter { !dropIndices.contains($0.header.fragIndex) } + parity
        XCTAssertEqual(survivors.count, data.count - dropIndices.count + parity.count)

        let reassembler = FrameReassembler(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let recovered = reassemble(survivors, into: reassembler)
        let rf = try XCTUnwrap(recovered, "m=2 must recover 2 losses per group")
        XCTAssertEqual(rf.avcc, frame, "the reassembled frame is byte-identical to the original")
        XCTAssertTrue(rf.recoveredViaFEC, "completion came via FEC recovery (a hole existed)")
        XCTAssertTrue(rf.keyframe)
    }

    /// CONTROL: the SAME 2-loss-per-group pattern on an `m == 1` (XOR-equivalent) wire CANNOT recover —
    /// XOR repairs at most ONE loss per group, so the frame is dropped (proving the m=2 success above
    /// is a genuine multi-loss capability, not an artifact of the harness).
    func testM1ControlFailsOnTwoLossesPerGroup() {
        let k = 5
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: k, parityCount: 1))
        let frame = multiGroupFrame(dataFragments: 2 * k)
        let (data, parity) = packetize(frame, packetizer: packetizer)
        XCTAssertEqual(data.count, 2 * k)
        XCTAssertEqual(parity.count, 2, "m=1 ⇒ exactly one parity per group")

        // Same 2-loss-per-group burst the m=2 path recovered.
        let dropIndices: Set<UInt16> = [0, 1, 5, 7]
        let survivors = data.filter { !dropIndices.contains($0.header.fragIndex) } + parity

        let reassembler = FrameReassembler(fec: RustReedSolomonFEC(groupSize: k, parityCount: 1))
        let recovered = reassemble(survivors, into: reassembler)
        XCTAssertNil(recovered, "m=1/XOR provably cannot recover 2 losses in one group")

        // And the frame is declared dropped once a newer frame advances the loss frontier.
        let next = multiGroupFrame(dataFragments: 1)
        let (nextData, _) = packetize(next, packetizer: packetizer)
        _ = reassembler.ingest(nextData[0])
        XCTAssertEqual(reassembler.nextDroppedFrame(), 0, "the unrecoverable frame is dropped, not wedged")
    }

    /// m + 1 = 3 losses in ONE group exceed the `m == 2` per-group budget: the frame fails GRACEFULLY
    /// — no recovery, no panic/crash, and the frame is dropped once the frontier advances.
    func testThreeLossesInOneGroupFailGracefully() {
        let k = 5
        let m = 2
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let frame = multiGroupFrame(dataFragments: 2 * k)
        let (data, parity) = packetize(frame, packetizer: packetizer)

        // 3 distinct holes in GROUP 0 (> m=2), group 1 clean.
        let dropIndices: Set<UInt16> = [0, 1, 2]
        let survivors = data.filter { !dropIndices.contains($0.header.fragIndex) } + parity

        let reassembler = FrameReassembler(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let recovered = reassemble(survivors, into: reassembler)
        XCTAssertNil(recovered, "3 losses > m=2 budget in one group is unrecoverable")

        // Graceful: advancing the frontier drops the frame; no trap was hit reaching here.
        let next = multiGroupFrame(dataFragments: 1)
        let (nextData, _) = packetize(next, packetizer: packetizer)
        _ = reassembler.ingest(nextData[0])
        XCTAssertEqual(reassembler.nextDroppedFrame(), 0, "frame dropped gracefully, no panic")
    }

    /// Mixed groups: group 0 loses 2 (== m, recoverable), group 1 loses 3 (> m, unrecoverable) ⇒ the
    /// WHOLE frame is still unrecoverable (a frame needs ALL data restored), and it drops gracefully.
    func testMixedRecoverableAndUnrecoverableGroupsDropsFrame() {
        let k = 5
        let m = 2
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let frame = multiGroupFrame(dataFragments: 2 * k)
        let (data, parity) = packetize(frame, packetizer: packetizer)

        // group 0: indices 0,1 (2 holes, == m). group 1: indices 5,6,7 (3 holes, > m).
        let dropIndices: Set<UInt16> = [0, 1, 5, 6, 7]
        let survivors = data.filter { !dropIndices.contains($0.header.fragIndex) } + parity
        let reassembler = FrameReassembler(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        XCTAssertNil(reassemble(survivors, into: reassembler), "one over-budget group dooms the frame")
    }

    // MARK: Env gate parse/clamp (pure, no process state)

    func testEnvGateDefaultsToM1() {
        XCTAssertEqual(AdaptiveFECPolicy.MultiLossFEC.resolveParityCount(env: [:]), 1, "unset ⇒ m=1")
        XCTAssertEqual(AdaptiveFECPolicy.MultiLossFEC.resolveGroupSize(env: [:]), 5, "unset ⇒ default k=5")
        XCTAssertFalse(
            AdaptiveFECPolicy.MultiLossFEC.resolveParityCount(env: ["AISLOPDESK_FEC_M": "1"]) >= 2,
            "m=1 is not active",
        )
    }

    func testEnvGateParsesAndClamps() {
        let mlf = AdaptiveFECPolicy.MultiLossFEC.self
        // In-range values pass through.
        XCTAssertEqual(mlf.resolveParityCount(env: ["AISLOPDESK_FEC_M": "2"]), 2)
        XCTAssertEqual(mlf.resolveGroupSize(env: ["AISLOPDESK_FEC_M": "2", "AISLOPDESK_FEC_K": "8"]), 8)
        // m clamps to [1, 8].
        XCTAssertEqual(mlf.resolveParityCount(env: ["AISLOPDESK_FEC_M": "0"]), 1, "m floored to 1")
        XCTAssertEqual(mlf.resolveParityCount(env: ["AISLOPDESK_FEC_M": "99"]), 8, "m capped to 8")
        XCTAssertEqual(mlf.resolveParityCount(env: ["AISLOPDESK_FEC_M": "garbage"]), 1, "non-numeric ⇒ m=1")
        // k clamps to [2, 64].
        XCTAssertEqual(
            mlf.resolveGroupSize(env: ["AISLOPDESK_FEC_M": "2", "AISLOPDESK_FEC_K": "1"]),
            2,
            "k floored to 2",
        )
        XCTAssertEqual(
            mlf.resolveGroupSize(env: ["AISLOPDESK_FEC_M": "2", "AISLOPDESK_FEC_K": "999"]),
            64,
            "k capped to 64",
        )
        // Joint GF(2^8) bound k + m <= 255 (degenerate huge-m, but proves the cap is applied).
        XCTAssertEqual(mlf.resolveParityCount(env: ["AISLOPDESK_FEC_M": "8"]), 8)
        XCTAssertLessThanOrEqual(
            mlf.resolveGroupSize(env: ["AISLOPDESK_FEC_M": "8", "AISLOPDESK_FEC_K": "64"]) + 8,
            255,
            "k + m must satisfy the GF(2^8) field bound",
        )
    }

    /// `wireTier` forces tier 0 only when multi-loss is active; with `m == 1` it is the identity (so
    /// the adaptive-FEC path is byte-identical). This asserts the PURE mapping for both inputs without
    /// relying on the process env (which is m=1 in CI).
    func testWireTierIsIdentityWhenInactive() {
        // The live process is m=1 (no env set in the test runner), so wireTier is the identity.
        XCTAssertFalse(AdaptiveFECPolicy.MultiLossFEC.isActive, "test runner defaults to m=1")
        for tier: UInt8 in 0...7 {
            XCTAssertEqual(
                AdaptiveFECPolicy.wireTier(adaptiveTier: tier), tier,
                "m=1 ⇒ wireTier passes the adaptive tier through unchanged (byte-identical)",
            )
        }
    }

    /// `makeFECScheme()` under the live (m=1) process env returns the byte-identical XOR-equivalent
    /// default: groupSize 5, parityCount 1.
    func testMakeFECSchemeDefaultIsM1() {
        let scheme = AdaptiveFECPolicy.makeFECScheme()
        XCTAssertEqual(scheme.parityCount, 1, "default scheme is m=1 (XOR-equivalent)")
        XCTAssertEqual(scheme.groupSize, 5, "default scheme is the prod g5")
    }

    // MARK: W12 — the settings overlay REACHES the FEC resolution (AISLOPDESK_FEC_M / _FEC_K)

    /// REACHES-CONSUMER (P1): a Settings override folded into ``EnvConfig/overlay`` changes the env the
    /// FEC resolvers read (`configEnv` → the pure `resolveParityCount`/`resolveGroupSize`), so a GUI
    /// toggle of `AISLOPDESK_FEC_M` / `_FEC_K` actually moves the parity/group the codec is built with.
    /// (The live `static let parityCount`/`groupSize` are forced once at process start by the same path,
    /// so this asserts the resolution the host/client share — not a per-call re-read.) An EMPTY overlay
    /// yields exactly today's default (m=1, k=5).
    func testOverlayReachesFECResolution() {
        let mlf = AdaptiveFECPolicy.MultiLossFEC.self
        EnvConfig.overlay = [:]
        defer { EnvConfig.overlay = [:] }

        // Empty overlay (and no FEC env in the test runner) ⇒ today's default: m=1, k=5.
        XCTAssertEqual(mlf.resolveParityCount(env: mlf.configEnv), 1, "empty overlay ⇒ default m=1")
        XCTAssertEqual(mlf.resolveGroupSize(env: mlf.configEnv), 5, "empty overlay ⇒ default k=5")

        // A settings override in the overlay is consulted by configEnv → the resolvers move.
        EnvConfig.overlay["AISLOPDESK_FEC_M"] = "3"
        EnvConfig.overlay["AISLOPDESK_FEC_K"] = "8"
        XCTAssertEqual(mlf.configEnv["AISLOPDESK_FEC_M"], "3", "overlay value flows into configEnv")
        XCTAssertEqual(mlf.resolveParityCount(env: mlf.configEnv), 3, "overlay AISLOPDESK_FEC_M=3 ⇒ m=3")
        XCTAssertEqual(mlf.resolveGroupSize(env: mlf.configEnv), 8, "overlay AISLOPDESK_FEC_K=8 ⇒ k=8")
    }

    /// SANITY: an m=2 frame with NO loss reassembles whole (the multi-parity append never corrupts a
    /// clean delivery) — guards against a packetizer/reassembler mismatch masking as "recovery".
    func testM2WholeFrameWithNoLossCompletes() throws {
        let k = 5
        let m = 2
        let packetizer = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let frame = multiGroupFrame(dataFragments: 2 * k)
        let (data, parity) = packetize(frame, packetizer: packetizer)
        let reassembler = FrameReassembler(fec: RustReedSolomonFEC(groupSize: k, parityCount: m))
        let rf = try XCTUnwrap(reassemble(data + parity, into: reassembler))
        XCTAssertEqual(rf.avcc, frame)
        XCTAssertFalse(rf.recoveredViaFEC, "no hole ⇒ not flagged as FEC-recovered")
    }
}
