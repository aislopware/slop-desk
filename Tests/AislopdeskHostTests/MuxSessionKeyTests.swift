import XCTest
@testable import AislopdeskHost

/// FIX A regression: host mux sessions MUST be namespaced by `(connectionID, channelID)`,
/// not `channelID` alone (round-3 FIX #2 keyed by channelID alone — a regression).
///
/// Every distinct client connection allocates `channelID` 1 for its FIRST pane
/// (`ChannelTable.allocate()` starts at 1, per connection), so a `channelID`-only map made
/// connection B's `channelOpen(1)` silently OVERWRITE connection A's live session at `1`
/// (orphaning A's PTY/master-fd), and made A's close-hook `removeMuxSession(1)` shut DOWN
/// B's live pane — cross-shutting a DIFFERENT client. This is socket-free: it exercises the
/// exact keyspace `HostServer.muxSessions` uses (`[MuxSessionKey: …]`), with `Int` standing
/// in for the live `MuxChannelSession` value so no PTY/NWListener is touched.
final class MuxSessionKeyTests: XCTestCase {

    func testSameChannelIDOnDifferentConnectionsAreDistinctKeys() {
        let connA = UUID()
        let connB = UUID()
        let a = MuxSessionKey(connectionID: connA, channelID: 1)
        let b = MuxSessionKey(connectionID: connB, channelID: 1)
        XCTAssertNotEqual(a, b, "channelID 1 on two different connections must be distinct keys")
        XCTAssertNotEqual(a.hashValue, b.hashValue) // not contractually required, but the bug is a collision
    }

    func testSameConnectionSameChannelIsTheSameKey() {
        let conn = UUID()
        XCTAssertEqual(
            MuxSessionKey(connectionID: conn, channelID: 3),
            MuxSessionKey(connectionID: conn, channelID: 3),
            "the same (connectionID, channelID) pair is idempotent — re-keys the same session"
        )
    }

    /// THE crash the composite key prevents: connection B's open at channelID 1 must NOT
    /// overwrite connection A's live session at channelID 1, and closing A's channelID 1 must
    /// NOT shut B's. Mirrors `spawnMuxChannel` insert + `removeMuxSession` remove exactly.
    func testTwoConnectionsSameChannelIDDoNotCrossOverwriteOrCrossShut() {
        let connA = UUID()
        let connB = UUID()
        // Stand-in for the live `MuxChannelSession` values (distinct sentinels per connection).
        var muxSessions: [MuxSessionKey: Int] = [:]

        // Connection A opens its first pane (channelID 1).
        muxSessions[MuxSessionKey(connectionID: connA, channelID: 1)] = 100
        // Connection B opens ITS first pane — also channelID 1 (per-connection allocator).
        muxSessions[MuxSessionKey(connectionID: connB, channelID: 1)] = 200

        // PRE-EXISTING overwrite/orphan leak the composite key closes: B did NOT clobber A.
        XCTAssertEqual(muxSessions[MuxSessionKey(connectionID: connA, channelID: 1)], 100)
        XCTAssertEqual(muxSessions[MuxSessionKey(connectionID: connB, channelID: 1)], 200)
        XCTAssertEqual(muxSessions.count, 2, "two distinct sessions coexist; no overwrite")

        // Connection A's close-hook removes ITS channelID 1 — and must NOT touch B's.
        muxSessions.removeValue(forKey: MuxSessionKey(connectionID: connA, channelID: 1))
        XCTAssertNil(muxSessions[MuxSessionKey(connectionID: connA, channelID: 1)])
        XCTAssertEqual(
            muxSessions[MuxSessionKey(connectionID: connB, channelID: 1)], 200,
            "closing A's channelID 1 must NOT cross-shut B's live channelID 1 session"
        )
    }

    /// One connection with many channels: distinct channelIDs under the same connection are
    /// distinct keys (the composite key does not over-collapse a single connection's panes).
    func testSameConnectionDistinctChannelsAreDistinctKeys() {
        let conn = UUID()
        var muxSessions: [MuxSessionKey: Int] = [:]
        muxSessions[MuxSessionKey(connectionID: conn, channelID: 1)] = 1
        muxSessions[MuxSessionKey(connectionID: conn, channelID: 3)] = 3
        XCTAssertEqual(muxSessions.count, 2)
        muxSessions.removeValue(forKey: MuxSessionKey(connectionID: conn, channelID: 1))
        XCTAssertEqual(muxSessions[MuxSessionKey(connectionID: conn, channelID: 3)], 3,
                       "closing one pane must not shut the connection's other panes")
    }
}
