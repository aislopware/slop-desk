#if canImport(Darwin)
import Darwin
#endif
import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// WF-3 relay-ordering tests.
///
/// The load-bearing claim of the whole relay is that output reaches the client (and the
/// `ReplayBuffer`) in true PTY read order. The bridge from the user-interactive read
/// queue onto the `HostSessionTransport` actor must therefore assign seqs in read order.
/// The previous implementation hopped each chunk onto the actor via a fresh detached
/// `Task` per chunk, which does NOT preserve order (independent tasks reach the actor in
/// scheduler order, not creation order) — under a burst it scrambled both the live stream
/// and the replayed tail. This test drives the REAL `HostSession` relay against a real
/// `HostSessionTransport` (client offline, so output is retained in the `ReplayBuffer`)
/// and asserts the retained bytes form a strictly-contiguous monotonic run.
final class RelayOrderingTests: XCTestCase {

    /// Floods the PTY with a long, strictly-increasing newline-delimited integer sequence
    /// (`seq 1 N`) and runs the full relay with the client offline so every chunk is
    /// retained in the `ReplayBuffer`. After the child exits, the retained `output`
    /// payloads (read back in ascending seq order) must decode to `1,2,3,…,k` — a perfect
    /// contiguous run from 1 with NO reordering — for the whole retained prefix (the kernel
    /// may truncate the very tail when the child exits, which is fine; we are testing
    /// ORDER, not completeness). A per-chunk detached-Task bridge interleaves chunk
    /// boundaries under this burst and breaks the contiguity at the first scramble; the
    /// ordered single-consumer FIFO bridge keeps it perfectly contiguous.
    func testBurstOutputRetainsInReadOrder() async throws {
        let n = 20000
        let pty = PTYProcess()
        try pty.spawn("/usr/bin/seq", arguments: ["1", "\(n)"], environment: HostEnvironment.curated())

        let transport = HostSessionTransport(sessionID: UUID())
        // Offline: sendOutput retains in the ReplayBuffer but writes nothing to a channel,
        // so we can inspect the exact seq->bytes mapping the bridge produced.
        await transport.setClientOnline(false)

        let session = HostSession(sessionID: transport.sessionID, pty: pty, transport: transport)
        session.startRelay()

        // Let the child run to completion and the FIFO bridge fully drain into the actor.
        _ = await pty.waitForExit()
        let settled = await pollUntilAsync(timeout: 5) {
            // Wait until the retained count stops growing (drain complete).
            let a = await transport.highestSeq
            try? await Task.sleep(nanoseconds: 50_000_000)
            let b = await transport.highestSeq
            return a == b && a > 0
        }
        XCTAssertTrue(settled, "relay never produced/settled any retained output")

        // Read the retained payloads back in ascending seq order; seqs must be strictly
        // ascending and the decoded integers a perfect contiguous run 1..k.
        let tail = await transport.replayTail(after: 0)
        XCTAssertFalse(tail.isEmpty, "no output was retained")
        var concatenated = Data()
        var lastSeq: Int64 = 0
        for message in tail {
            guard case let .output(seq, bytes) = message else { continue }
            XCTAssertGreaterThan(seq, lastSeq, "replay tail seqs must be strictly ascending")
            lastSeq = seq
            concatenated.append(bytes)
        }
        let numbers = Self.parseNumbers(concatenated)
        // A meaningful burst must have been retained (empirically ~4.5k+ before any tail
        // truncation); a trivially-short stream would not exercise concurrent scheduling.
        XCTAssertGreaterThan(numbers.count, 2000, "burst too small to exercise the bridge: \(numbers.count)")
        XCTAssertEqual(numbers.first, 1, "stream must start at 1")
        // The decisive check: numbers[i] == i+1 for the ENTIRE retained run. Any reordering
        // by the bridge puts a value out of place here.
        var firstBad: (index: Int, value: Int)?
        for (i, value) in numbers.enumerated() where value != i + 1 {
            firstBad = (i, value); break
        }
        XCTAssertNil(
            firstBad,
            "retained byte stream is out of order — bridge did not preserve read order "
            + "(at index \(firstBad?.index ?? -1) expected \((firstBad?.index ?? 0) + 1) got \(firstBad?.value ?? -1))")

        session.shutdown()
    }

    // MARK: helpers

    /// Parses the newline-delimited integers from the (CR-cooked) PTY byte stream.
    ///
    /// Cooked-mode `OPOST|ONLCR` maps `\n` -> `\r\n`, and the line discipline can emit a
    /// run of CRs at a boundary under load (we have observed `\r\r\n`). We strip ALL `\r`
    /// bytes before splitting on `\n` so the integers parse regardless of CR runs — this
    /// is a pure decode detail of the PTY's cooked output, NOT the byte ORDER (the order
    /// is what this test checks, and CR placement does not affect it). Note: splitting a
    /// Swift `String` on a `Character` would fail anyway, because `"\r\n"` is a single
    /// grapheme cluster (the classic CRLF gotcha) — so we work on raw bytes.
    private static func parseNumbers(_ data: Data) -> [Int] {
        data
            .filter { $0 != 0x0D }   // drop all CR (0x0D); cooked output may emit CR runs
            .split(separator: 0x0A)  // split on LF (0x0A)
            .compactMap { Int(String(decoding: $0, as: UTF8.self)) }
    }

    private func pollUntilAsync(timeout: TimeInterval, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await predicate()
    }
}
