import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// 2026-07-10 — the host is the single source of truth for the sidebar's By-Project key (wire type
/// 34): it derives the pane's cwd (OSC-7 sniff, else a prompt-edge probe), resolves the git
/// toplevel with a pure walk, emits ONLY on change edges, and re-asserts the latched truth on
/// reattach — so a reconnecting client renders the final sections immediately, with no `gitStatus`
/// RPC sweep and no cwd-fallback→toplevel re-bucketing flash (the reported "nháy 1 cái").
///
/// 2026-07-11 (findings 2+3) — the derivation is now split: the SYNC part (warm-up gate, cwd scan,
/// prompt-edge probe preference, `lastCwdTruth` latch) runs on the read-loop thread; the resolver's
/// blocking `stat(2)` walk runs asynchronously (production: `metadataQueue`; tests inject
/// `projectKeyResolveExecutorOverride`) and its type-34 lands on the CONTROL sender — so a cwd on a
/// hung network mount can never freeze the pane's output. OSC-7-only batches are ignored until the
/// first command edge (plugin-manager pre-prompt `cd` noise), and at a prompt edge the probe beats
/// a same-batch, possibly-stale OSC-7.
///
/// Driven WITHOUT a PTY or running relay (hang-safety): the derivation seam
/// (`deriveProjectKeyForTesting`) exercises the exact code `ingestPTYChunk` runs over each chunk's
/// sniffed batch, `cwdProbeOverride` stands in for the `proc_pidinfo` prompt-edge probe, and the
/// injected resolve executor makes the async hop deterministic.
///
/// REVERT-TO-FAIL: removing the `deriveProjectKey` call from `ingestPTYChunk` fails the ingest
/// test; removing the cwd/projectKey lines from `reestablishActivityOnReattach` fails the
/// re-assert tests; resolving inline on the caller fails the slow-resolve test's pending count.
final class MuxChannelSessionProjectKeyTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; truths driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
        // Deterministic default for these tests: run each dispatched resolve INLINE (production
        // hops to metadataQueue). The slow-resolve tests override this with a deferred executor.
        session.projectKeyResolveExecutorOverride = { $0() }
        return session
    }

    /// A BEL-terminated OSC sequence as raw PTY bytes (`ESC ] <body> BEL`).
    private func osc(_ body: String) -> Data { Data("\u{1B}]\(body)\u{07}".utf8) }

    /// Warm the session past the first command edge (finding 3a): OSC-7-only batches are ignored
    /// until a `.commandStatus` has been observed, so every test that feeds `.cwd(...)` alone must
    /// first cross this gate — exactly like a real shell printing its first prompt. On an
    /// unspawned PTY the prompt-edge probe answers nil, so the warm-up itself derives nothing.
    private func warmUp(_ session: MuxChannelSession) {
        session.deriveProjectKeyForTesting(from: [.commandStatus(.idle(exitCode: 0, durationMS: 1))])
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "warm-up on an unspawned PTY (probe nil, no OSC-7) must not emit",
        )
    }

    /// Drains control-out of live-emission side-products (the Blocks segmenter's type-28 goes
    /// straight to control-out at ingest) so a re-assert batch stands on its own.
    private func drainControlOut(_ session: MuxChannelSession) {
        while session.takeControlBatchForTesting() != nil {}
    }

    /// A real on-disk repo shape: `<tmp>/repo/.git/` + `<tmp>/repo/sub/` — the resolver walks the
    /// actual filesystem in these tests (the walk itself is pinned pure in ProjectKeyResolverTests).
    private func makeTempRepo() throws -> (root: String, sub: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-pk-\(UUID().uuidString)")
        let sub = base.appendingPathComponent("repo/sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true,
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root.path, sub.path)
    }

    /// Lock-guarded FIFO of deferred resolve closures (the slow-resolver executor stand-in).
    private final class PendingResolves: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []
        func append(_ item: @escaping @Sendable () -> Void) {
            lock.lock()
            work.append(item)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return work.count
        }

        /// Runs every deferred resolve in dispatch order (mirrors the serial metadataQueue).
        func runAll() {
            lock.lock()
            let items = work
            work.removeAll()
            lock.unlock()
            for item in items { item() }
        }
    }

    /// Lock-guarded flag for asserting the probe was (not) consulted.
    private final class ProbeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flagged = false
        func set() {
            lock.lock()
            flagged = true
            lock.unlock()
        }

        var wasSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flagged
        }
    }

    // MARK: - change-edge derivation (the seam mirrors ingestPTYChunk's per-chunk call)

    func testOSC7CwdDerivesToplevelKeyOnceAndDedupes() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        warmUp(session) // OSC-7-only batches derive only after the first command edge
        session.deriveProjectKeyForTesting(from: [.cwd(sub)])
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(root)],
            "a cwd inside a repo emits the TOPLEVEL as the project key (host-computed, no RPC)",
        )
        session.deriveProjectKeyForTesting(from: [.cwd(sub)])
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "an unchanged cwd is dropped at the first dedupe anchor — every prompt's OSC-7 must not re-emit",
        )
        session.deriveProjectKeyForTesting(from: [.cwd(root)])
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "a cwd change WITHIN the same project resolves the same key — no emission, no client re-render",
        )
    }

    func testPromptEdgeProbeCoversShellsWithoutOSC7() throws {
        // Starship / hookless shells emit no OSC-7 — the 133;B/D prompt edge triggers ONE probe.
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        session.cwdProbeOverride = { sub }
        session.deriveProjectKeyForTesting(from: [.commandStatus(.idle(exitCode: 0, durationMS: 5))])
        XCTAssertEqual(session.takeControlBatchForTesting(), [.projectKey(root)])
        session.deriveProjectKeyForTesting(from: [.title("mid-command chunk")])
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "no cwd signal and no prompt edge (every mid-command chunk) derives nothing — zero probe cost",
        )
    }

    func testNonRepoCwdFallsBackToCwdAsKey() throws {
        let session = makeSession()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-pk-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        warmUp(session)
        session.deriveProjectKeyForTesting(from: [.cwd(base.path)])
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(base.path)],
            "no repo anywhere above the cwd → the cwd itself is the (stable) key",
        )
    }

    // MARK: - ingest path (the live wiring, not just the seam)

    func testIngestedOSC7ChunkLatchesTruthForReattach() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        warmUp(session) // the ingest path shares the same first-command-edge gate
        session.ingestPTYChunkForTesting(osc("7;file://\(sub)"))
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.cwd(sub), .projectKey(root)],
            "reattach re-tells the latched cwd + host-computed key — the returning client renders the final sections immediately",
        )
    }

    // MARK: - Finding 2 (2026-07-11) — the resolver walk must never block the read-loop thread

    /// The stat-walk can hang indefinitely (dead NFS/SMB/FUSE mount). A resolve that has not
    /// completed must not stop `ingestPTYChunk` from returning — the bytes flow, and the type-34
    /// emission lands once the (deferred) resolve finishes.
    func testSlowResolveNeverBlocksIngestAndEmitsWhenDone() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        let pending = PendingResolves()
        session.projectKeyResolveExecutorOverride = { pending.append($0) }
        warmUp(session)

        // Ingest returns with the resolve still pending — the exact hung-mount shape: the walk
        // has not run, yet the chunk was journaled/sniffed/enqueued and the latch took the cwd.
        session.ingestPTYChunkForTesting(osc("7;file://\(sub)"))
        XCTAssertEqual(pending.count, 1, "the cwd change dispatched exactly one deferred resolve")
        var preResolve: [WireMessage] = []
        while let batch = session.takeControlBatchForTesting() {
            preResolve.append(contentsOf: batch)
        }
        let earlyKeys = preResolve.filter { message in
            if case .projectKey = message { return true }
            return false
        }
        XCTAssertEqual(earlyKeys, [], "no type-34 may be emitted before the resolve has run")

        pending.runAll()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(root)],
            "the emission lands on the control sender once the deferred resolve completes",
        )
    }

    /// Two rapid `cd`s: the FIRST resolve completes after the SECOND cwd was latched — it must be
    /// dropped (latest cd wins), and only the newest cwd's key emits.
    func testLaterCdSupersedesAPendingStaleResolve() throws {
        let session = makeSession()
        let (rootA, subA) = try makeTempRepo()
        let (rootB, subB) = try makeTempRepo()
        XCTAssertNotEqual(rootA, rootB, "sanity: two distinct repos")
        let pending = PendingResolves()
        session.projectKeyResolveExecutorOverride = { pending.append($0) }
        warmUp(session)

        session.deriveProjectKeyForTesting(from: [.cwd(subA)])
        session.deriveProjectKeyForTesting(from: [.cwd(subB)])
        XCTAssertEqual(pending.count, 2, "each cwd change dispatched its own resolve")
        pending.runAll() // FIFO — exactly the serial metadataQueue's order
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(rootB)],
            "the stale resolve (older cd) is dropped at completion — only the latest cd's key emits",
        )
    }

    // MARK: - Finding 3 (2026-07-11) — warm-up gate + probe-beats-stale-OSC-7 at prompt edges

    /// (a) A plugin manager that `cd`s into its git-cloned cache dir BEFORE the first prompt emits
    /// OSC-7 for a directory the user was never in; latching it persisted a bogus sidebar section
    /// client-side. OSC-7-only batches must be IGNORED until the first command edge.
    func testPreFirstPromptOSC7IsIgnoredUntilFirstCommandEdge() throws {
        let session = makeSession()
        let (_, pluginCache) = try makeTempRepo() // a git-cloned plugin cache — tempting but bogus
        session.deriveProjectKeyForTesting(from: [.cwd(pluginCache)])
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "pre-first-prompt OSC-7 (plugin-manager cd noise) must not derive a project key",
        )
        session.reestablishActivityOnReattachForTesting()
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "pre-first-prompt OSC-7 must not even LATCH — a reattach would re-assert the bogus dir",
        )

        // After the first command edge the gate is open: a genuine post-prompt cd flows normally.
        warmUp(session)
        let (root, sub) = try makeTempRepo()
        session.deriveProjectKeyForTesting(from: [.cwd(sub)])
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(root)],
            "post-warm-up OSC-7 changes derive normally",
        )
    }

    /// (b) When a `.cwd` OSC-7 and the `.commandStatus(.idle)` prompt edge arrive in the SAME
    /// batch, ground truth (the probe) is available at that exact moment — a possibly-stale OSC-7
    /// must not win over it.
    func testProbeBeatsSameBatchOSC7AtPromptEdge() throws {
        let session = makeSession()
        let (rootTruth, subTruth) = try makeTempRepo()
        warmUp(session)
        let (_, subStale) = try makeTempRepo()
        session.cwdProbeOverride = { subTruth }
        session.deriveProjectKeyForTesting(
            from: [.cwd(subStale), .commandStatus(.idle(exitCode: 0, durationMS: 1))],
        )
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(rootTruth)],
            "at a prompt edge the probe (ground truth) must beat a same-batch, possibly-stale OSC-7",
        )
        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.cwd(subTruth), .projectKey(rootTruth)],
            "the latches carry the PROBED truth, not the stale OSC-7",
        )
    }

    /// (b, fallback) The probe can fail (unspawned/gone shell) — then the batch's OSC-7 value is
    /// still honoured at the prompt edge.
    func testProbeFailureFallsBackToSameBatchOSC7AtPromptEdge() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        warmUp(session)
        session.cwdProbeOverride = { nil }
        session.deriveProjectKeyForTesting(
            from: [.cwd(sub), .commandStatus(.idle(exitCode: 0, durationMS: 1))],
        )
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(root)],
            "when the probe fails, the same-batch OSC-7 is the best remaining truth",
        )
    }

    /// (post-warm-up) OSC-7 still wins MID-COMMAND (no prompt edge): a `cd` inside a running
    /// script re-groups without the probe ever being consulted (zero probe cost off prompt edges).
    func testOSC7WinsMidCommandAfterWarmUpWithoutProbing() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        warmUp(session)
        let probed = ProbeFlag()
        session.cwdProbeOverride = {
            probed.set()
            return "/never-used"
        }
        session.deriveProjectKeyForTesting(from: [.cwd(sub)])
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.projectKey(root)],
            "a mid-command OSC-7 cwd change (no prompt edge) still derives normally after warm-up",
        )
        XCTAssertFalse(probed.wasSet, "no prompt edge in the batch → the probe is never consulted")
    }

    // MARK: - reattach re-assert

    func testReattachReassertsLatestTruthAfterDetachedWindowChange() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        warmUp(session)
        session.deriveProjectKeyForTesting(from: [.cwd("/")])
        // The cwd moved while no client was attached (the emission rode the wiped control-out):
        session.deriveProjectKeyForTesting(from: [.cwd(sub)])
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.cwd(sub), .projectKey(root)],
            "the re-assert reads the LATCH (updated at sniff time), so a detached-window cd is not lost",
        )
    }

    func testReattachQuietWhenNoCwdEverObserved() {
        let session = makeSession()
        session.reestablishActivityOnReattachForTesting()
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "a session that never observed a cwd contributes nothing — no chatter on an ordinary reconnect",
        )
    }
}
