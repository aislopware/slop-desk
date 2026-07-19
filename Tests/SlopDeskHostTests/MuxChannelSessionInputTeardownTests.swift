import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Writer-vs-teardown quiescence for the PTY input path: EVERY write (client `input` frames and
/// the agent-control raw injection) funnels through the session's ONE serial input queue, and
/// `shutdown()` closes the write gate then DRAINS that queue BEFORE `closeMaster()` — so a
/// blocking `write(2)` can never race the close onto a recycled fd number (the write-side TOCTOU).
/// Headless: unspawned PTY (fd −1), the write override observes what passes the gate.
final class MuxChannelSessionInputTeardownTests: XCTestCase {
    private func makeSession(channelID: UInt32 = 4) -> MuxChannelSession {
        let data = MuxSubChannel(channelID: channelID, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: channelID, channel: .control) { _, _ in }
        return MuxChannelSession(channelID: channelID, pty: PTYProcess(), data: data, control: control)
    }

    /// The load-bearing drain: `shutdown()` must not return (and so must not `closeMaster()`)
    /// while an input write is still in flight on the input queue. The override sleeps like a
    /// write parked on a full kernel PTY buffer; the completion flag proves shutdown waited.
    func testShutdownDrainsInFlightInputWriteBeforeReturning() {
        let session = makeSession()
        let writeStarted = expectation(description: "write block running on the input queue")
        let writeFinished = Flag()
        session.ptyWriteOverrideForTesting = { _ in
            writeStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.2) // a write blocked on a full PTY buffer
            writeFinished.set()
        }
        session.writeRawForControl(Data("stuck paste".utf8))
        wait(for: [writeStarted], timeout: 2)

        session.pty.completeExitForTesting(code: 0) // child observed dead → bounded waits
        session.shutdown()
        XCTAssertTrue(
            writeFinished.isSet,
            "shutdown() must drain the serial input queue before closeMaster() — an in-flight write may not outlive the close",
        )
    }

    /// The teardown gate: a write enqueued AFTER `shutdown()` is dropped, never written — bytes
    /// for a dead pane must not land anywhere (least of all a recycled fd).
    func testWritesAfterShutdownAreDropped() {
        let session = makeSession()
        let delivered = ByteRecorder()
        session.ptyWriteOverrideForTesting = { delivered.append($0) }

        session.writeRawForControl(Data("before".utf8))
        pollUntil { delivered.all == [Data("before".utf8)] }

        session.pty.completeExitForTesting(code: 0)
        session.shutdown()
        session.writeRawForControl(Data("after".utf8))
        Thread.sleep(forTimeInterval: 0.1) // give a (wrongly) surviving write time to surface
        XCTAssertEqual(delivered.all, [Data("before".utf8)], "the gate drops every post-shutdown write")
    }

    /// The client `input` relay path lands on the SAME gated writer (not a private per-relay
    /// queue): an `input` frame delivered on the data sub-channel surfaces through the override.
    func testClientInputFramesLandOnTheGatedWriter() async throws {
        let data = MuxSubChannel(channelID: 7, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 7, channel: .control) { _, _ in }
        let session = MuxChannelSession(channelID: 7, pty: PTYProcess(), data: data, control: control)
        let delivered = ByteRecorder()
        session.ptyWriteOverrideForTesting = { delivered.append($0) }
        session.startRelay()

        await data.deliver(payload: WireMessage.input(Data("keys".utf8)).encode())

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if delivered.all.contains(Data("keys".utf8)) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            delivered.all, [Data("keys".utf8)],
            "the relay input path writes through the serial gated writer",
        )

        session.pty.completeExitForTesting(code: 0)
        session.shutdownDetached()
    }

    // MARK: - Helpers

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool { lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class ByteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        func append(_ bytes: Data) { lock.lock()
            stored.append(bytes)
            lock.unlock()
        }

        var all: [Data] { lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Synchronous poll (the callers are non-async test bodies parked on background-queue work).
    private func pollUntil(timeout: TimeInterval = 2, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("condition not reached within \(timeout)s")
    }
}
