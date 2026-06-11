import XCTest
@testable import AislopdeskProtocol

/// Pure allocator + lifecycle tests for `ChannelTable`. No IO, no sockets.
final class ChannelTableTests: XCTestCase {

    func testAllocatesOddMonotonicIDs() {
        var table = ChannelTable()
        let ids = (0 ..< 5).map { _ in table.allocate() }
        XCTAssertEqual(ids, [1, 3, 5, 7, 9], "client-initiated ids are odd and monotonic")
        for id in ids {
            XCTAssertEqual(table.state(of: id), .idle, "a freshly allocated id starts idle")
        }
    }

    func testNeverReusesALiveID() {
        var table = ChannelTable()
        let first = table.allocate()       // 1
        table.open(first)
        let second = table.allocate()      // 3 — must not collide with the live id
        XCTAssertNotEqual(first, second)
        XCTAssertEqual([first, second], [1, 3])
    }

    func testNeverReusesAClosedIDEither() {
        // Monotonicity is across closes too: a stale frame for a dead id can never
        // collide with a freshly allocated channel.
        var table = ChannelTable()
        let a = table.allocate() // 1
        table.open(a)
        XCTAssertEqual(table.localClose(a), .halfClosed)
        XCTAssertEqual(table.remoteClose(a), .closed)
        let b = table.allocate() // 3, not a reuse of 1
        XCTAssertEqual(b, 3)
        XCTAssertEqual(table.state(of: a), .closed, "the dead id is retained as closed")
    }

    func testLifecycleIdleToOpen() {
        var table = ChannelTable()
        let id = table.allocate()
        XCTAssertEqual(table.state(of: id), .idle)
        XCTAssertFalse(table.isOpen(id))
        table.open(id)
        XCTAssertEqual(table.state(of: id), .open)
        XCTAssertTrue(table.isOpen(id))
    }

    /// idle/open -> halfClosed -> closed, with both-sides-close symmetry: the FIRST
    /// close (from either side) half-closes; the SECOND fully closes.
    func testLifecycleBothSidesCloseSymmetryLocalThenRemote() {
        var table = ChannelTable()
        let id = table.allocate()
        table.open(id)
        XCTAssertEqual(table.localClose(id), .halfClosed, "first (local) close half-closes")
        XCTAssertFalse(table.isOpen(id), "a half-closed channel is not fully open")
        XCTAssertEqual(table.remoteClose(id), .closed, "second (remote) close fully closes")
    }

    func testLifecycleBothSidesCloseSymmetryRemoteThenLocal() {
        // Symmetric: the order of the two closes does not matter.
        var table = ChannelTable()
        let id = table.allocate()
        table.open(id)
        XCTAssertEqual(table.remoteClose(id), .halfClosed, "first (remote) close half-closes")
        XCTAssertEqual(table.localClose(id), .closed, "second (local) close fully closes")
    }

    func testClosingAnIdleChannelHalfThenFullCloses() {
        // A channel that never opened can still be closed (open() is not a precondition).
        var table = ChannelTable()
        let id = table.allocate()
        XCTAssertEqual(table.state(of: id), .idle)
        XCTAssertEqual(table.localClose(id), .halfClosed)
        XCTAssertEqual(table.remoteClose(id), .closed)
    }

    func testReopeningAClosingChannelIsIgnored() {
        // open() must not resurrect a half-closed or closed channel.
        var table = ChannelTable()
        let id = table.allocate()
        table.open(id)
        XCTAssertEqual(table.localClose(id), .halfClosed)
        table.open(id) // should be a no-op
        XCTAssertEqual(table.state(of: id), .halfClosed)
        XCTAssertEqual(table.remoteClose(id), .closed)
        table.open(id) // still a no-op
        XCTAssertEqual(table.state(of: id), .closed)
    }

    func testLiveChannelIDsExcludesOnlyFullyClosed() {
        var table = ChannelTable()
        let a = table.allocate() // 1 idle
        let b = table.allocate() // 3 open
        let c = table.allocate() // 5 half-closed
        let d = table.allocate() // 7 fully closed
        table.open(b)
        table.localClose(c)
        table.localClose(d); table.remoteClose(d)

        XCTAssertEqual(table.liveChannelIDs, [a, b, c], "idle, open, half-closed are live; closed is not")
        XCTAssertFalse(table.liveChannelIDs.contains(d))
    }

    func testStateOfUnknownIDIsNil() {
        let table = ChannelTable()
        XCTAssertNil(table.state(of: 42))
        XCTAssertFalse(table.isOpen(42))
    }

    /// R6 #5 regression: a `channelClose` for an id that was NEVER registered must create NO table
    /// entry — otherwise a hostile peer grows `states` without bound by spamming closes for arbitrary
    /// peer-chosen ids (a router memory-DoS). The close still reports `.closed`, it just leaves no
    /// permanent allocation behind.
    func testRemoteCloseForUnknownIDCreatesNoEntry() {
        var table = ChannelTable()
        for id in stride(from: UInt32(1000), to: 1000 + 5000, by: 2) {
            XCTAssertEqual(table.remoteClose(id), .closed, "a close for an unknown id reports dead")
        }
        XCTAssertTrue(table.liveChannelIDs.isEmpty, "no live channels were created by stray closes")
        XCTAssertNil(table.state(of: 1000), "a stray close for an unknown id must leave NO retained entry")
        // A locally-allocated id still flows through the normal half-close → closed machine and IS
        // retained (the monotonic-no-reuse guarantee for OUR ids is unaffected).
        let mine = table.allocate()
        table.open(mine)
        XCTAssertEqual(table.localClose(mine), .halfClosed)
        XCTAssertEqual(table.remoteClose(mine), .closed)
        XCTAssertEqual(table.state(of: mine), .closed, "our own closed id is retained (no reuse)")
    }
}
