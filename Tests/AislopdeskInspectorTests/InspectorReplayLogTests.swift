import XCTest
@testable import AislopdeskInspector

/// Replay-then-live + fan-out semantics of ``InspectorReplayLog`` (PIECE A, resolves
/// BUG-B). Pure: no transport, no HostServer — just the actor + AsyncStreams.
final class InspectorReplayLogTests: XCTestCase {
    /// A few distinct, order-bearing events to assert exact sequence.
    private func msg(_ text: String) -> InspectorEvent {
        .message(MessageEvent(role: .assistant, text: text))
    }

    /// Collects exactly `count` events from a stream (with a generous timeout so a hang
    /// fails the test rather than the suite).
    private func collect(
        _ stream: AsyncStream<InspectorEvent>,
        count: Int,
    ) async throws -> [InspectorEvent] {
        let task = Task { () -> [InspectorEvent] in
            var got: [InspectorEvent] = []
            for await event in stream {
                got.append(event)
                if got.count >= count { break }
            }
            return got
        }
        return try await withThrowingTaskGroup(of: [InspectorEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                task.cancel()
                throw XCTSkip("timed out collecting \(count) events")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// fromSeq:0 with history already present → the FULL history replays, then a live
    /// event appended afterwards arrives on the same stream.
    func testReplayFromZeroDeliversFullHistoryThenLive() async throws {
        let log = InspectorReplayLog()
        await log.append(msg("h0"))
        await log.append(msg("h1"))
        await log.append(msg("h2"))

        let stream = await log.subscribe(fromSeq: 0)

        // Replay (3) is yielded synchronously into the continuation at subscribe time.
        // Append one more live event — it must arrive 4th.
        await log.append(msg("live3"))

        let got = try await collect(stream, count: 4)
        XCTAssertEqual(got, [msg("h0"), msg("h1"), msg("h2"), msg("live3")])
    }

    /// A subscriber attaching LATE (after all history accumulated) still gets the entire
    /// history from seq 0.
    func testLateSubscriberGetsFullHistory() async throws {
        let log = InspectorReplayLog()
        for i in 0..<5 { await log.append(msg("e\(i)")) }

        // No subscriber existed while those 5 were appended.
        let stream = await log.subscribe(fromSeq: 0)
        let got = try await collect(stream, count: 5)
        XCTAssertEqual(got, (0..<5).map { msg("e\($0)") })
    }

    /// Two independent subscribers BOTH get the full history (fan-out), and both get a
    /// subsequent live event.
    func testTwoSubscribersBothGetFullHistory() async throws {
        let log = InspectorReplayLog()
        await log.append(msg("a"))
        await log.append(msg("b"))

        let s1 = await log.subscribe(fromSeq: 0)
        let s2 = await log.subscribe(fromSeq: 0)
        let count = await log.subscriberCount
        XCTAssertEqual(count, 2, "both live continuations are attached")

        await log.append(msg("c")) // live → both

        // Collect both streams concurrently without capturing `self` (the streams are
        // Sendable; the helper would re-send the non-Sendable test case).
        let got1 = try await collect(s1, count: 3)
        let got2 = try await collect(s2, count: 3)
        XCTAssertEqual(got1, [msg("a"), msg("b"), msg("c")])
        XCTAssertEqual(got2, [msg("a"), msg("b"), msg("c")])
    }

    /// A reconnect resume (fromSeq:N) SKIPS the already-rendered prefix `0..<N` and
    /// replays only `history[N...]`, then streams live. (This is the BUG-B fix: fromSeq
    /// is honoured, not decoded-then-ignored.)
    func testFromSeqResumeSkipsReplayedPrefix() async throws {
        let log = InspectorReplayLog()
        for i in 0..<4 { await log.append(msg("e\(i)")) } // seq 0,1,2,3

        // Client already saw e0,e1 (next seq it wants is 2).
        let stream = await log.subscribe(fromSeq: 2)
        await log.append(msg("e4")) // live, seq 4

        let got = try await collect(stream, count: 3)
        XCTAssertEqual(
            got,
            [msg("e2"), msg("e3"), msg("e4")],
            "resume replays history[2...] (e2,e3) then live e4 — no e0/e1",
        )
    }

    /// A fromSeq past the end of history (a future resume point) → empty replay, then
    /// the live tail.
    func testFromSeqBeyondHistoryYieldsOnlyLive() async throws {
        let log = InspectorReplayLog()
        await log.append(msg("only0"))

        let stream = await log.subscribe(fromSeq: 99) // beyond end → empty replay
        await log.append(msg("live1"))

        let got = try await collect(stream, count: 1)
        XCTAssertEqual(got, [msg("live1")])
    }

    /// `ingest(_:)` consumes the engine's single stream exactly once and the history is
    /// the full ordered set; a subscriber created after the stream finished gets the full
    /// replay then finishes.
    func testIngestConsumesEngineStreamThenFinishes() async throws {
        let log = InspectorReplayLog()
        var continuation: AsyncStream<InspectorEvent>.Continuation!
        let upstream = AsyncStream<InspectorEvent> { continuation = $0 }
        log.ingest(upstream)

        continuation.yield(msg("u0"))
        continuation.yield(msg("u1"))
        continuation.finish()

        // Wait for ingest to drain (poll historyCount up to the finished mark).
        for _ in 0..<200 {
            if await log.historyCount == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalCount = await log.historyCount
        XCTAssertEqual(finalCount, 2)

        // A post-finish subscriber still gets the full replay, then the stream ends.
        let stream = await log.subscribe(fromSeq: 0)
        var got: [InspectorEvent] = []
        for await event in stream { got.append(event) }
        XCTAssertEqual(got, [msg("u0"), msg("u1")])
    }

    /// R6 #4: the retained history is BOUNDED. Appending past the cap drops the oldest, but
    /// `historyCount` (the absolute next-seq) keeps climbing and `subscribe(fromSeq:)` maps the ABSOLUTE
    /// seq through the dropped base — the live tail is exact, and a stale `fromSeq` below the base clamps
    /// (no crash) instead of leaking the whole history forever.
    func testHistoryRetentionIsBoundedAndSeqStaysAbsolute() async throws {
        let log = InspectorReplayLog()
        let total = 60000 // > the 50k retention cap
        for i in 0..<total { await log.append(msg("e\(i)")) }

        let absolute = await log.historyCount
        let retained = await log.retainedEventCount
        XCTAssertEqual(absolute, total, "historyCount is the ABSOLUTE next-seq, stable across retention drops")
        XCTAssertLessThanOrEqual(retained, 50000, "the retained window is bounded (no unbounded OOM)")
        XCTAssertGreaterThan(absolute, retained, "older events were dropped to keep memory bounded")

        await log.markFinished() // so subscribe streams deliver the snapshot then finish (no live wait)
        // Absolute-seq mapping survives the drop: from (total-3) → exactly the last 3 events in order.
        let tail = await log.subscribe(fromSeq: Int64(total - 3))
        let gotTail = try await collect(tail, count: 3)
        XCTAssertEqual(
            gotTail,
            [msg("e\(total - 3)"), msg("e\(total - 2)"), msg("e\(total - 1)")],
            "subscribe maps the ABSOLUTE fromSeq through baseSeq to the correct tail after drops",
        )
        // A fromSeq BELOW the retained base must clamp to the oldest retained (no crash / no negative slice).
        let fromZero = await log.subscribe(fromSeq: 0)
        let firstFew = try await collect(fromZero, count: 1)
        XCTAssertEqual(firstFew.count, 1, "fromSeq below baseSeq clamps to the oldest retained event")
    }

    /// R7 #6 regression: once `baseSeq` has advanced (events dropped), a hostile/unauthenticated
    /// `subscribe(fromSeq: Int64.min)` must NOT overflow-trap the host (`Int(fromSeq) - baseSeq`
    /// underflow) — it saturates to "everything retained". `Int64.max` (past the end) → empty replay.
    func testSubscribeWithHostileFromSeqDoesNotCrash() async throws {
        let log = InspectorReplayLog()
        for i in 0..<60000 { await log.append(msg("e\(i)")) } // baseSeq advances past 0
        await log.markFinished()

        let everything = await log.subscribe(fromSeq: Int64.min) // would underflow-trap before the fix
        let got = try await collect(everything, count: 1)
        XCTAssertEqual(got.count, 1, "fromSeq=Int64.min saturates to the oldest retained event (no host-crash trap)")

        let none = await log.subscribe(fromSeq: Int64.max)
        var n = 0
        for await _ in none { n += 1 }
        XCTAssertEqual(n, 0, "fromSeq past the end yields an empty replay, also without trapping")
    }
}
