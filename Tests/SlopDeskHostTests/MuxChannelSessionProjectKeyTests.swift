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
/// Driven WITHOUT a PTY or running relay (hang-safety): the derivation seam
/// (`deriveProjectKeyMessagesForTesting`) exercises the exact code `ingestPTYChunk` runs over each
/// chunk's sniffed batch, and `cwdProbeOverride` stands in for the `proc_pidinfo` prompt-edge probe.
///
/// REVERT-TO-FAIL: removing the `deriveProjectKeyMessages` append from `ingestPTYChunk` fails the
/// ingest test; removing the cwd/projectKey lines from `reestablishActivityOnReattach` fails the
/// re-assert tests.
final class MuxChannelSessionProjectKeyTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; truths driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// A BEL-terminated OSC sequence as raw PTY bytes (`ESC ] <body> BEL`).
    private func osc(_ body: String) -> Data { Data("\u{1B}]\(body)\u{07}".utf8) }

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

    // MARK: - change-edge derivation (the seam mirrors ingestPTYChunk's per-chunk call)

    func testOSC7CwdDerivesToplevelKeyOnceAndDedupes() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.cwd(sub)]),
            [.projectKey(root)],
            "a cwd inside a repo emits the TOPLEVEL as the project key (host-computed, no RPC)",
        )
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.cwd(sub)]), [],
            "an unchanged cwd is dropped at the first dedupe anchor — every prompt's OSC-7 must not re-emit",
        )
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.cwd(root)]), [],
            "a cwd change WITHIN the same project resolves the same key — no emission, no client re-render",
        )
    }

    func testPromptEdgeProbeCoversShellsWithoutOSC7() throws {
        // Starship / hookless shells emit no OSC-7 — the 133;B/D prompt edge triggers ONE probe.
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        session.cwdProbeOverride = { sub }
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.commandStatus(.idle(exitCode: 0, durationMS: 5))]),
            [.projectKey(root)],
        )
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.title("mid-command chunk")]), [],
            "no cwd signal and no prompt edge (every mid-command chunk) derives nothing — zero probe cost",
        )
    }

    func testNonRepoCwdFallsBackToCwdAsKey() throws {
        let session = makeSession()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-pk-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(
            session.deriveProjectKeyMessagesForTesting(from: [.cwd(base.path)]),
            [.projectKey(base.path)],
            "no repo anywhere above the cwd → the cwd itself is the (stable) key",
        )
    }

    // MARK: - ingest path (the live wiring, not just the seam)

    func testIngestedOSC7ChunkLatchesTruthForReattach() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        session.ingestPTYChunkForTesting(osc("7;file://\(sub)"))
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.cwd(sub), .projectKey(root)],
            "reattach re-tells the latched cwd + host-computed key — the returning client renders the final sections immediately",
        )
    }

    // MARK: - reattach re-assert

    func testReattachReassertsLatestTruthAfterDetachedWindowChange() throws {
        let session = makeSession()
        let (root, sub) = try makeTempRepo()
        _ = session.deriveProjectKeyMessagesForTesting(from: [.cwd("/")])
        // The cwd moved while no client was attached (the emission rode the wiped FIFO/control):
        _ = session.deriveProjectKeyMessagesForTesting(from: [.cwd(sub)])
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
