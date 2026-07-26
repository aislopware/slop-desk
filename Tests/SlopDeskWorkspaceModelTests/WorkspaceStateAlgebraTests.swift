import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The convergence proof for docs/45, standing BEFORE any socket exists.
///
/// The whole multi-client design rests on three algebraic claims about `diff`/`apply`. If they hold,
/// duplicate / reordered / lost frames need no machinery at all — no retransmit path, no ack
/// bookkeeping beyond a single acked base, no delta log to compact. If they do not hold, no amount
/// of transport care rescues it. So they are pinned here, headlessly, with no host and no wire.
final class WorkspaceStateAlgebraTests: XCTestCase {
    // MARK: - Fixtures

    private func key(_ kind: UInt8, _ objectID: UUID, _ field: UInt8) -> WorkspaceKey {
        WorkspaceKey(kind: kind, objectID: objectID, field: field)
    }

    private func state(_ pairs: [(WorkspaceKey, String)]) -> HostWorkspaceState {
        HostWorkspaceState(pairs.map { WorkspaceEntry(key: $0.0, value: Data($0.1.utf8)) })
    }

    /// A deterministic UUID generator — `Math.random`-free so a failure is reproducible from the seed
    /// alone.
    private struct Rng {
        var seed: UInt64
        mutating func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }

        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func uuid(_ pool: [UUID]) -> UUID { pool[int(pool.count)] }
    }

    // MARK: - The three claims

    /// `apply(diff(a, b), a) == b`. Without this a diff does not mean what it says.
    func testDiffApplyIdentity() {
        let a = UUID(), b = UUID()
        let from = state([(key(3, a, 1), "nvim"), (key(3, a, 5), "/tmp"), (key(2, b, 0), "tab")])
        let to = state([(key(3, a, 1), "main.go - NVIM"), (key(3, a, 8), "vi ."), (key(2, b, 0), "tab")])

        XCTAssertEqual(from.applying(to.diff(from: from)), to, "a diff must carry its base to its target")
    }

    /// `apply(d, apply(d, s)) == apply(d, s)`. This is what makes a DUPLICATED frame a no-op, and it
    /// holds because a diff assigns rather than mutates.
    func testApplyIsIdempotent() {
        let a = UUID()
        let from = state([(key(3, a, 1), "old")])
        let to = state([(key(3, a, 1), "new"), (key(3, a, 4), "1")])
        let d = to.diff(from: from)

        let once = from.applying(d)
        XCTAssertEqual(once.applying(d), once, "applying a diff twice must equal applying it once")
    }

    /// A snapshot round-trips exactly. The bootstrap path for a client that has never seen this host.
    func testSnapshotRoundTrip() throws {
        let a = UUID(), b = UUID()
        let host = state([
            (key(3, a, 1), "main.go - NVIM"), (key(3, a, 5), "/Volumes/x"),
            (key(2, b, 0), "tab"), (key(0, WorkspaceObjectKind.rootObjectID, 2), "mac-studio"),
        ])

        let decoded = try WorkspaceStateCodec.decodeSnapshot(WorkspaceStateCodec.encodeSnapshot(host))
        XCTAssertEqual(decoded, host)
    }

    /// Emission order is canonical, so a snapshot's BYTES are deterministic — the precondition for a
    /// stable golden vector and for a diff that never churns on Dictionary iteration order.
    func testSnapshotBytesAreOrderIndependent() {
        let a = UUID(), b = UUID()
        let pairs: [(WorkspaceKey, String)] = [
            (key(3, a, 1), "one"), (key(0, WorkspaceObjectKind.rootObjectID, 0), "two"),
            (key(2, b, 4), "three"), (key(3, a, 0), "four"),
        ]
        let forward = WorkspaceStateCodec.encodeSnapshot(state(pairs))
        let reversed = WorkspaceStateCodec.encodeSnapshot(state(pairs.reversed()))
        XCTAssertEqual(forward, reversed, "insertion order must not reach the wire")
    }

    /// A title RETIREMENT must be a SET of a zero-length value, never a delete. An empty type-21 is
    /// the agent title-ownership hand-back, so "field present and empty" and "field absent" mean
    /// different things and the diff must preserve the distinction.
    func testTitleRetirementIsASetNotADelete() {
        let pane = UUID()
        let titled = state([(key(3, pane, 3), "✳ Claude Code")])
        let retired = state([(key(3, pane, 3), "")])

        let d = retired.diff(from: titled)
        XCTAssertEqual(d.deletes, [], "retiring a field must not delete its key")
        XCTAssertEqual(d.sets.count, 1)
        XCTAssertEqual(d.sets.first?.value, Data(), "the retirement is an explicit zero-length value")
        XCTAssertEqual(titled.applying(d), retired)
    }

    /// Removing an OBJECT is what produces deletes — every field under one id, together.
    func testRemovingAnObjectDeletesAllItsFields() {
        let pane = UUID(), other = UUID()
        var host = state([
            (key(3, pane, 1), "a"), (key(3, pane, 5), "b"), (key(3, other, 1), "keep"),
        ])
        let before = host
        host.removeObject(kind: 3, objectID: pane)

        let d = host.diff(from: before)
        XCTAssertEqual(d.sets, [], "a pure removal sets nothing")
        XCTAssertEqual(Set(d.deletes), Set([key(3, pane, 1), key(3, pane, 5)]))
        XCTAssertEqual(before.applying(d), host)
    }

    // MARK: - The real thing: randomized convergence under a hostile channel

    /// 1000 randomized mutation sequences delivered over a channel that DROPS, DUPLICATES and
    /// REORDERS frames, with the host always diffing from the replica's last ACKED state.
    ///
    /// This is the mosh SSP argument executed rather than asserted: because each diff is recomputed
    /// from the acked base, a dropped frame self-heals on the next tick and a duplicate is inert — so
    /// the replica converges on the host with no retransmit path on either side.
    func testRandomizedConvergenceUnderDropDuplicateReorder() {
        let pool = (0..<6).map { _ in UUID() }
        var rng = Rng(seed: 0x5D05_DE5C)

        for round in 0..<1000 {
            var host = HostWorkspaceState()
            var replica = HostWorkspaceState()
            var acked = HostWorkspaceState() // what the host BELIEVES the replica holds
            var inFlight: [WorkspaceStateDiff] = []

            for step in 0..<12 {
                // Mutate the host.
                let objectID = rng.uuid(pool)
                let kind = UInt8(rng.int(6))
                let field = UInt8(rng.int(4))
                switch rng.int(4) {
                case 0: host.removeObject(kind: kind, objectID: objectID)
                case 1: host.set(WorkspaceKey(kind: kind, objectID: objectID, field: field), Data())
                default:
                    host.set(
                        WorkspaceKey(kind: kind, objectID: objectID, field: field),
                        Data("r\(round)s\(step)".utf8),
                    )
                }

                // The host always diffs from the ACKED base, never from the last SENT state.
                inFlight.append(host.diff(from: acked))

                // Hostile channel: drop, duplicate, reorder.
                if rng.int(4) == 0, !inFlight.isEmpty { inFlight.removeFirst() } // drop
                if rng.int(4) == 0, let last = inFlight.last { inFlight.append(last) } // duplicate
                if rng.int(3) == 0, inFlight.count >= 2 { inFlight.swapAt(0, inFlight.count - 1) } // reorder

                // Deliver whatever survived; only a delivered frame advances the ack.
                if rng.int(2) == 0 {
                    for d in inFlight {
                        replica = replica.applying(d)
                        acked = replica
                    }
                    inFlight.removeAll()
                }
            }

            // The steady-state tick: one more diff from the acked base, always delivered.
            replica = replica.applying(host.diff(from: acked))
            XCTAssertEqual(replica, host, "replica must converge on the host after one clean tick (round \(round))")
        }
    }

    /// The reason `epoch` is non-optional (docs/45 §5.5): a diff based on a DIFFERENT document is
    /// silently applicable — it produces a state that is neither the host's nor the replica's, with
    /// no detector. The epoch is what makes that frame droppable; this test pins the hazard so the
    /// check can never be "simplified" away.
    func testDiffAgainstAForeignBaseSilentlyDiverges() {
        let pane = UUID()
        let hostA = state([(key(3, pane, 1), "A"), (key(3, pane, 5), "/a")])
        let hostB = state([(key(3, pane, 1), "B")])
        let replicaOfB = hostB

        // A diff computed against A's base, misapplied to a replica of B.
        let foreign = hostA.diff(from: HostWorkspaceState())
        XCTAssertNotEqual(
            replicaOfB.applying(foreign), hostB,
            "a mis-based diff APPLIES cleanly and corrupts — nothing in the algebra detects it, which "
                + "is precisely why the envelope carries an epoch and a base stateNum",
        )
    }
}
