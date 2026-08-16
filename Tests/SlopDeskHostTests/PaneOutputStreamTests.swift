import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The output path's three awkward cases, against a real daemon.
///
/// `SupervisedPaneSurvivalTests` proves a pane's CHILD survives; this proves its STREAM does — that
/// the bytes arrive once, from the right place, and that a gate asserted at an awkward moment is
/// still honoured. Each of these was a live bug: a doubled transcript, a terminal that never redrew
/// again after a supervisor reconnect, and a pause the pane never heard about.
///
/// Skips when `slopdesk-superd` is not built — see ``SuperdFixture``.
final class PaneOutputStreamTests: XCTestCase {
    private var superd: SuperdFixture?

    override func setUpWithError() throws {
        superd = try SuperdFixture()
    }

    override func tearDown() {
        superd = nil
    }

    /// Everything one stream saw, plus whether it ended. Its own type rather than ``PaneOutput``
    /// because these tests need the `fromOffset` the support helper deliberately hides.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var ended = false
        private var events: [SniffedEvent] = []

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        /// How many bytes this stream has delivered — the offset a resume picks up at when the
        /// subscribe started at 0.
        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes.count
        }

        var isEnded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }

        func append(_ chunk: Data, sniffed: [SniffedEvent] = []) {
            lock.lock()
            bytes.append(chunk)
            events.append(contentsOf: sniffed)
            lock.unlock()
        }

        /// What the stream handed over WITH the bytes — the pairing this type exists to observe.
        var sniffed: [SniffedEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func end() {
            lock.lock()
            ended = true
            lock.unlock()
        }

        /// Blocks until `needle` shows up, or the timeout elapses. Returns whether it did.
        func waitFor(_ needle: String, timeout: TimeInterval = 10) -> Bool {
            waitUntil(timeout: timeout) { self.text.contains(needle) }
        }

        func waitForEnd(timeout: TimeInterval = 10) -> Bool {
            waitUntil(timeout: timeout) { self.isEnded }
        }

        private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return condition()
        }
    }

    private func stream(_ pane: PTYProcess, from offset: UInt64 = 0) -> (PaneOutputStream, Sink) {
        let sink = Sink()
        let stream = pane.makeOutputStream(
            fromOffset: offset,
            onChunk: { chunk, _, sniffed, _ in sink.append(chunk, sniffed: sniffed) },
            onEOF: { sink.end() },
        )
        return (stream, sink)
    }

    /// A pane that waits for a keystroke between its two halves, so a test can put a subscribe
    /// exactly between them instead of hoping a sleep lands there. Echo off: the newline that wakes
    /// it must not turn up in the assertions as output.
    private func pausingPane(_ fixture: SuperdFixture, first: String, second: String) throws -> PTYProcess {
        try fixture.pty(
            "/bin/sh",
            arguments: ["-c", "stty -echo; printf '\(first)'; read _line; printf '\(second)'"],
            environment: ["PATH": "/usr/bin:/bin"],
            paneID: "stream-\(UUID().uuidString.prefix(8))",
        )
    }

    /// THE double-history case. An adopted pane's transcript is already on disk, so a subscribe
    /// from 0 would print the user's whole session a second time — and re-feed it to the sniffer,
    /// the block ledger and the screen engine. Resuming at the offset the last life stopped at
    /// delivers the rest and nothing else.
    ///
    /// In production that offset comes from superd — it numbers this stream and writes the file, so
    /// `journalInfo.head` is the same number without a second process having to keep track
    /// (`docs/51` §6.8). Here it is counted from the bytes this stream actually received, which is
    /// what makes the assertion about the SUBSCRIBE rather than about the bookkeeping.
    func testResumingAtAnOffsetDeliversTheRestAndNotTheBacklog() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try pausingPane(fixture, first: "FIRSTHALF", second: "SECONDHALF")

        let (early, seenEarly) = stream(pane)
        early.start()
        XCTAssertTrue(seenEarly.waitFor("FIRSTHALF"), "got: \(seenEarly.text.debugDescription)")
        let boundary = UInt64(seenEarly.byteCount)
        XCTAssertGreaterThan(boundary, 0, "a stream that has received bytes has a boundary")
        early.stop()

        // The next daemon life, resuming exactly where the transcript stops.
        let (resumed, seenLate) = stream(pane, from: boundary)
        resumed.start()
        defer { resumed.stop() }
        XCTAssertEqual(write(pane.masterFD, "\n", 1), 1)
        XCTAssertTrue(seenLate.waitFor("SECONDHALF"), "got: \(seenLate.text.debugDescription)")
        XCTAssertFalse(
            seenLate.text.contains("FIRSTHALF"),
            "the resumed stream replayed history the journal already holds — the user sees their "
                + "session twice: \(seenLate.text.debugDescription)",
        )
    }

    /// `fromNowOn` is the answer when there is no recorded boundary at all: hostd holds a transcript
    /// it cannot align with superd's ring (one is distilled, the other is raw bytes), so the only
    /// safe place to start is the head. Losing the gap is the deliberate trade — printing it twice
    /// is the bug.
    func testFromNowOnStartsAtTheHeadWithNoBacklog() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try pausingPane(fixture, first: "ALREADYSEEN", second: "BRANDNEW")

        // Make sure the first half really is in the ring before the "from now on" subscribe, or the
        // test would pass by simply being early.
        let (early, seenEarly) = stream(pane)
        early.start()
        XCTAssertTrue(seenEarly.waitFor("ALREADYSEEN"), "got: \(seenEarly.text.debugDescription)")
        early.stop()

        let (fresh, seen) = stream(pane, from: PaneOutputStream.fromNowOn)
        fresh.start()
        defer { fresh.stop() }
        XCTAssertEqual(write(pane.masterFD, "\n", 1), 1)
        XCTAssertTrue(seen.waitFor("BRANDNEW"), "got: \(seen.text.debugDescription)")
        XCTAssertFalse(
            seen.text.contains("ALREADYSEEN"),
            "an offset past the ring's head must clamp to the head, not to zero: \(seen.text.debugDescription)",
        )
    }

    /// A pause asserted BEFORE the subscribe still reaches the pane.
    ///
    /// The gate does exactly this on every adopted pane: `MuxChannelSession` enqueues the restore
    /// preamble — often past the bounded queue's high-water mark — and only then starts the stream.
    /// While `setPaused` was gated on `start()` having happened, that first pause was dropped on the
    /// floor, and because ``PausableQueueGate`` latches a decision as applied and re-sends only on a
    /// CHANGE, nothing ever corrected it: the gate believed the pane was paused, the subscription
    /// opened wide, and the whole backlog arrived with no backpressure at all.
    func testAPauseAssertedBeforeTheSubscribeIsStillHonoured() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try pausingPane(fixture, first: "", second: "AFTERTHEGATE")

        let (gated, seen) = stream(pane)
        gated.setPaused(true) // before `start()` — the whole point
        gated.start()
        defer { gated.stop() }

        XCTAssertEqual(write(pane.masterFD, "\n", 1), 1)
        XCTAssertFalse(
            seen.waitFor("AFTERTHEGATE", timeout: 1.0),
            "superd read the master while the pane was paused — the never-drop backpressure "
                + "contract is only real if the pause arrives: \(seen.text.debugDescription)",
        )

        gated.setPaused(false)
        XCTAssertTrue(
            seen.waitFor("AFTERTHEGATE"),
            "and lifting it must deliver what the kernel buffer held: \(seen.text.debugDescription)",
        )
    }

    /// A supervisor reconnect must put the stream back, from where it left off.
    ///
    /// The pane and its shell are untouched by a control-socket drop, so nothing looks broken — but
    /// the client's handler table went with the connection. Without a re-subscribe the terminal
    /// renders nothing ever again while keystrokes keep travelling: a window the user types into
    /// that never answers.
    func testResubscribeResumesWithoutRepeatingWhatArrived() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try pausingPane(fixture, first: "BEFOREDROP", second: "AFTERDROP")

        let (live, seen) = stream(pane)
        live.start()
        defer { live.stop() }
        XCTAssertTrue(seen.waitFor("BEFOREDROP"), "got: \(seen.text.debugDescription)")

        XCTAssertTrue(live.resubscribe(), "a live pane must re-open")
        XCTAssertEqual(write(pane.masterFD, "\n", 1), 1)
        XCTAssertTrue(seen.waitFor("AFTERDROP"), "got: \(seen.text.debugDescription)")
        XCTAssertEqual(
            seen.text.components(separatedBy: "BEFOREDROP").count - 1, 1,
            "the re-opened subscription must resume at the offset the last chunk left off, not "
                + "replay the ring: \(seen.text.debugDescription)",
        )
    }

    /// `resubscribe()` is a no-op on a stream that never started or has already stopped, and says
    /// so — the caller uses that answer to decide whether the session is over.
    func testResubscribeRefusesAStreamThatIsNotRunning() throws {
        let fixture = try XCTUnwrap(superd)
        let pane = try pausingPane(fixture, first: "X", second: "Y")
        defer {
            pane.release(kill: true)
            pane.closeMaster()
        }

        let (never, _) = stream(pane)
        XCTAssertFalse(never.resubscribe(), "nothing to re-open before `start()`")

        let (done, _) = stream(pane)
        done.start()
        done.stop()
        XCTAssertFalse(done.resubscribe(), "a stopped stream stays stopped")
    }
}
