import XCTest
@testable import AislopdeskVideoHost

/// LOSS-TOLERANCE #1 (2026-06-10): the dedicated paced-send lane. Socket-free — the lane's send
/// closure records into a locked recorder; pacing gaps are kept small and assertions use generous
/// tolerances + polling so the tests are timing-robust on a loaded CI box.
final class VideoSendLaneTests: XCTestCase {

    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(bytes: Data, channel: VideoChannel, at: TimeInterval)] = []
        func record(_ bytes: Data, _ channel: VideoChannel) {
            lock.lock(); entries.append((bytes, channel, ProcessInfo.processInfo.systemUptime)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
        var all: [(bytes: Data, channel: VideoChannel, at: TimeInterval)] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }

    private func makeLane(_ recorder: SendRecorder) -> VideoSendLane {
        VideoSendLane(send: { bytes, channel in recorder.record(bytes, channel) })
    }

    private func outgoings(_ tag: UInt8, count: Int) -> [VideoSendScheduler.Outgoing] {
        (0..<count).map { VideoSendScheduler.Outgoing(channel: .video, bytes: Data([tag, UInt8($0)])) }
    }

    /// Poll until `recorder.count >= target` or the deadline passes.
    private func waitForCount(_ recorder: SendRecorder, _ target: Int, deadline: TimeInterval = 3.0) async {
        let start = ProcessInfo.processInfo.systemUptime
        while recorder.count < target, ProcessInfo.processInfo.systemUptime - start < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testWireOrderPreservedAcrossJobs() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        defer { lane.close() }
        for tag: UInt8 in 0..<3 {
            lane.enqueue(VideoSendLane.Job(outgoings: outgoings(tag, count: 4), gapNanos: 0, chunkFragments: 8))
        }
        await waitForCount(recorder, 12)
        let sent = recorder.all
        XCTAssertEqual(sent.count, 12)
        // Strict in-order: job 0's datagrams, then job 1's, then job 2's, each internally ordered.
        let expected: [Data] = (0..<3).flatMap { tag in (0..<4).map { Data([UInt8(tag), UInt8($0)]) } }
        XCTAssertEqual(sent.map(\.bytes), expected)
        XCTAssertTrue(sent.allSatisfy { $0.channel == .video })
    }

    /// THE defect this lane fixes: enqueue must return immediately even when the job paces slowly.
    func testEnqueueNeverBlocksOnPacing() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        defer { lane.close() }
        // 64 datagrams, chunk 8, 5ms gap → ≥35ms of wire pacing.
        let job = VideoSendLane.Job(outgoings: outgoings(7, count: 64), gapNanos: 5_000_000, chunkFragments: 8)
        let t0 = ProcessInfo.processInfo.systemUptime
        lane.enqueue(job)
        let enqueueSeconds = ProcessInfo.processInfo.systemUptime - t0
        XCTAssertLessThan(enqueueSeconds, 0.020, "enqueue slept on pacing — the pump would stall again")
        await waitForCount(recorder, 64)
        XCTAssertEqual(recorder.count, 64, "the paced job must still fully transmit")
        // And the transmission really was paced (not a single blast): first→last spans ≥ 3 gaps.
        let sent = recorder.all
        XCTAssertGreaterThan(sent[63].at - sent[0].at, 0.015)
    }

    func testFlushDropsQueuedJobsAndAbortsMidPace() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        defer { lane.close() }
        // Job A: 16 chunks of 1 × 25ms gap ≈ 375ms total. Job B queued behind it.
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(1, count: 16), gapNanos: 25_000_000, chunkFragments: 1))
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(2, count: 4), gapNanos: 0, chunkFragments: 8))
        await waitForCount(recorder, 2, deadline: 0.5)   // job A is mid-pace
        lane.flush()
        let countAtFlush = recorder.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        let sent = recorder.all
        // Job B (tag 2) must never hit the wire; job A stops within one chunk of the flush point.
        XCTAssertFalse(sent.contains { $0.bytes.first == 2 }, "flushed queued job must not transmit")
        XCTAssertLessThanOrEqual(recorder.count, countAtFlush + 1, "mid-pace job must abort at the next chunk boundary")
        XCTAssertLessThan(recorder.count, 16)
    }

    func testCloseIsTerminal() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        lane.close()
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(9, count: 4), gapNanos: 0, chunkFragments: 8))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.count, 0, "enqueue after close must be a no-op")
    }

    /// F3 kfDup, lane edition: the duplicate copy's leading delay time-separates the two copies.
    func testLeadingDelaySeparatesDuplicateCopy() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        defer { lane.close() }
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(1, count: 3), gapNanos: 0, chunkFragments: 8))
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(1, count: 3), gapNanos: 0, chunkFragments: 8,
                                       leadingDelayNanos: 60_000_000))
        await waitForCount(recorder, 6)
        let sent = recorder.all
        XCTAssertEqual(sent.count, 6)
        // Copy 2's first datagram lands ≥ ~half the configured delay after copy 1's last (sleep
        // never fires early; the tolerance only guards scheduler overshoot measurement noise).
        XCTAssertGreaterThan(sent[3].at - sent[2].at, 0.030)
    }

    func testSmallJobSendsSingleShot() async {
        let recorder = SendRecorder()
        let lane = makeLane(recorder)
        defer { lane.close() }
        // count ≤ chunkFragments ⇒ one shot even with a huge gap configured.
        lane.enqueue(VideoSendLane.Job(outgoings: outgoings(5, count: 8), gapNanos: 1_000_000_000, chunkFragments: 8))
        await waitForCount(recorder, 8, deadline: 0.5)
        let sent = recorder.all
        XCTAssertEqual(sent.count, 8)
        XCTAssertLessThan(sent[7].at - sent[0].at, 0.050, "≤chunk-size job must not pace")
    }
}
