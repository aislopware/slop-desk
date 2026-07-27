import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// The PTY grid is a HOST-RESOLVED fact (docs/45 §8.3): a monotone `min` fold over the subscribers
/// that hold an open pane channel, applied through ONE writer.
///
/// Real PTYs, because the thing under test IS the `TIOCSWINSZ` the kernel ends up holding — a
/// bookkeeping-only assertion would pass on a build that folds perfectly and never calls the ioctl.
/// `/bin/cat` rather than a shell: it stays alive on a pty (so the fd outlives the assertions) and
/// reads no startup files, so nothing here can touch the developer's shell history.
final class MuxChannelSessionResizeFoldTests: XCTestCase {
    // MARK: Rig

    private var spawned: [PTYProcess] = []
    private var sessions: [MuxChannelSession] = []
    private var directories: [URL] = []

    override func tearDown() {
        for session in sessions { session.shutdown() }
        for pty in spawned { pty.terminate() }
        for url in directories { try? FileManager.default.removeItem(at: url) }
        sessions = []
        spawned = []
        directories = []
    }

    private func makePTY(cols: UInt16 = 80, rows: UInt16 = 24) throws -> PTYProcess {
        let pty = PTYProcess()
        try pty.spawn("/bin/cat", environment: HostEnvironment.curated(), cols: cols, rows: rows)
        spawned.append(pty)
        return pty
    }

    private func makeSession(
        pty: PTYProcess,
        resizeDebounce: Duration = .zero,
        sizeSettle: Duration = .milliseconds(750),
        journal: ScrollbackJournal? = nil,
        control: MuxSubChannel? = nil,
    ) -> MuxChannelSession {
        let session = MuxChannelSession(
            channelID: 1,
            pty: pty,
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: control ?? MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            resizeDebounce: resizeDebounce,
            sizeSettle: sizeSettle,
            scrollbackJournal: journal,
        )
        sessions.append(session)
        return session
    }

    /// Bounded poll on the LIVE `TIOCGWINSZ` — never an unbounded PTY read (the 40-minute hang).
    @discardableResult
    private func pollGrid(
        _ pty: PTYProcess,
        untilCols cols: UInt16,
        rows: UInt16,
        timeout: TimeInterval = 5,
    ) -> (rows: UInt16, cols: UInt16) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = pty.currentWindowSize() ?? (rows: 0, cols: 0)
        while Date() < deadline {
            last = pty.currentWindowSize() ?? (rows: 0, cols: 0)
            if last.cols == cols, last.rows == rows { return last }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return last
    }

    /// Asserts the grid STAYS at `cols`×`rows` for `seconds` — the shape a "nothing applied it" proof
    /// needs, since the absence of an event cannot be awaited.
    private func assertGridHolds(
        _ pty: PTYProcess,
        cols: UInt16,
        rows: UInt16,
        seconds: TimeInterval,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let live = pty.currentWindowSize() ?? (rows: 0, cols: 0)
            guard live.cols == cols, live.rows == rows else {
                XCTFail("\(message) — grid moved to \(live.cols)x\(live.rows)", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func deliver(_ control: MuxSubChannel, _ messages: [WireMessage]) {
        let exp = expectation(description: "control-delivered")
        Task {
            for message in messages { await control.deliver(payload: message.encode()) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - The fold

    /// The grid is `min(cols)` / `min(rows)` over the contributing set — the whole reason the policy
    /// settles instead of flapping. Two clients holding one pane at different widths converge on the
    /// smaller one and STAY there, however often either of them types.
    func testTheGridIsTheMinimumOverContributions() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty)
        session.startRelay() // registers the primary contributor

        let second: MuxSubscriberID = 7
        session.addResizeContributor(second, sizePassive: false)
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        session.scheduleResize(from: second, cols: 100, rows: 50, px: 0, py: 0)
        session.applyResolvedGrid()

        let grid = pollGrid(pty, untilCols: 100, rows: 40)
        XCTAssertEqual(grid.cols, 100, "the narrower client decides the width")
        XCTAssertEqual(grid.rows, 40, "…and the shorter one the height, independently")
    }

    /// A size-passive subscriber is IN the set and contributes NOTHING. iOS is passive by default, so
    /// a phone attaching to a Studio's nvim must not crush it to a phone's width.
    func testASizePassiveContributorContributesNothing() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty)
        session.startRelay()

        let phone: MuxSubscriberID = 7
        session.addResizeContributor(phone, sizePassive: true)
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        session.scheduleResize(from: phone, cols: 40, rows: 12, px: 0, py: 0)
        session.applyResolvedGrid()

        let grid = pollGrid(pty, untilCols: 120, rows: 40)
        XCTAssertEqual(grid.cols, 120, "the phone's 40 columns are not in the fold")
        XCTAssertEqual(grid.rows, 40)

        XCTAssertEqual(
            session.resizeContributionsForWorkspace.first(where: { $0.subscriber == phone })?.contributes,
            false,
            "…and the roster says so, which is what lets the phone render a labelled letterbox",
        )
    }

    /// A pane whose contributing set EMPTIES keeps its last size. Snapping back to 80×24 when the
    /// last viewer leaves would reflow a running build for nobody's benefit.
    func testZeroContributorsKeepTheLastSize() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty)
        session.startRelay()
        session.scheduleResize(cols: 132, rows: 50, px: 0, py: 0)
        session.applyResolvedGrid()
        XCTAssertEqual(pollGrid(pty, untilCols: 132, rows: 50).cols, 132)

        session.removeResizeContributor()
        session.applyResolvedGrid()

        assertGridHolds(pty, cols: 132, rows: 50, seconds: 0.3, "an empty set resolves to nothing at all")
        XCTAssertTrue(
            session.resizeContributionsForWorkspace.isEmpty,
            "the set really is empty — otherwise the assertion above passes for the wrong reason",
        )
    }

    /// The settle arms on a CONTRIBUTOR-SET change, never on an ordinary resize frame.
    ///
    /// Arming it on every frame would put 750 ms between a divider drag and the shell noticing. It
    /// exists so a burst of JOINS resolves once — which is a different edge, and this pins both
    /// halves with a 60-second settle that could not possibly be the thing that applied anything.
    func testTheSettleArmsOnAJoinAndNotOnAResizeFrame() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty, resizeDebounce: .zero, sizeSettle: .seconds(60))
        session.startRelay()
        XCTAssertFalse(session.isSizeSettlingForTesting, "the first contributor has nothing to coalesce with")

        // An ordinary frame from the ONLY contributor: applied by the 16 ms-class debounce.
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        XCTAssertEqual(
            pollGrid(pty, untilCols: 120, rows: 40).cols, 120,
            "a resize frame is not made to wait out the settle",
        )

        // A JOIN into a pane somebody already holds: the set changed, so the fold is held.
        session.addResizeContributor(7, sizePassive: false)
        XCTAssertTrue(session.isSizeSettlingForTesting, "a join arms the settle")
        session.scheduleResize(from: 7, cols: 80, rows: 25, px: 0, py: 0)
        assertGridHolds(
            pty, cols: 120, rows: 40, seconds: 0.4,
            "an offer arriving mid-settle joins the fold rather than applying on its own",
        )

        // The flush paths (ack / bye / channel close) bypass BOTH timers, always.
        session.applyResolvedGrid()
        let settled = pollGrid(pty, untilCols: 80, rows: 25)
        XCTAssertEqual(settled.cols, 80, "one apply, at the folded minimum")
        XCTAssertEqual(settled.rows, 25)
    }

    /// A size-PASSIVE subscriber joining or leaving changes the membership without changing the
    /// arithmetic, so there is nothing to settle. Arming on it would hold every Mac's resize for
    /// 750 ms every time a phone glanced at the pane.
    func testAPassiveJoinDoesNotArmTheSettle() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty, resizeDebounce: .zero, sizeSettle: .seconds(60))
        session.startRelay()
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        XCTAssertEqual(pollGrid(pty, untilCols: 120, rows: 40).cols, 120)

        session.addResizeContributor(7, sizePassive: true)
        XCTAssertFalse(session.isSizeSettlingForTesting, "a passive join cannot move the fold")
        session.removeResizeContributor(7)
        XCTAssertFalse(session.isSizeSettlingForTesting, "…and neither can a passive leave")

        // Still responsive on the short debounce, which is the whole point of not arming.
        session.scheduleResize(cols: 100, rows: 30, px: 0, py: 0)
        XCTAssertEqual(
            pollGrid(pty, untilCols: 100, rows: 30).cols, 100,
            "the Mac's own resize is not held behind a settle nothing needed",
        )
    }

    // MARK: - The one writer

    /// The ctl socket's `resize` verb writes the SAME four things a client resize does.
    ///
    /// It used to be a second, independent `TIOCSWINSZ` that skipped the journal's size sidecar, so
    /// after any `slopdesk-ctl resize` the sidecar described a geometry the PTY no longer had — and
    /// the next daemon life re-rendered the journaled bytes at that stale width, mis-wrapping every
    /// line that the PATH-B transcript join stitches across the scrollback/grid boundary.
    func testResizeForControlRecordsTheJournalSizeSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-resize-sidecar-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let store = ScrollbackJournalStore(directory: directory)
        let sessionID = UUID()

        let pty = try makePTY()
        let session = makeSession(pty: pty, journal: store.journal(for: sessionID))
        session.startRelay()

        let sidecar = directory.appendingPathComponent("\(sessionID.uuidString).scrollback.size")
        func pollSidecar(until expected: String) -> String? {
            let deadline = Date().addingTimeInterval(5)
            var last: String?
            while Date() < deadline {
                last = try? String(contentsOf: sidecar, encoding: .utf8)
                if last == expected { return last }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return last
        }
        XCTAssertEqual(pollSidecar(until: "24 80\n"), "24 80\n", "startRelay seeds the spawn-time size")

        session.resizeForControl(rows: 50, cols: 132)

        XCTAssertEqual(
            pollGrid(pty, untilCols: 132, rows: 50).cols, 132,
            "the ctl verb still applies the size it was given",
        )
        XCTAssertEqual(
            pollSidecar(until: "50 132\n"), "50 132\n",
            "…and records it, exactly as the client path does",
        )
    }

    /// The other half of routing the ctl verb through the one writer: the delayed second `SIGWINCH`
    /// that makes a shell repaint its prompt at the FINAL size, which the ctl path did not schedule.
    func testResizeForControlSchedulesTheRedrawNudge() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty)
        session.startRelay()
        XCTAssertFalse(session.hasArmedRedrawNudgeForTesting, "nothing has resized yet")

        session.resizeForControl(rows: 50, cols: 132)

        XCTAssertTrue(
            session.hasArmedRedrawNudgeForTesting,
            "an orchestrator's resize leaves the prompt repainted, not stranded mid-reflow",
        )
    }

    /// A ctl resize is an OVERRIDE, and a one-shot one: the next client offer still wins. A sticky
    /// override would make every pane an orchestrator ever touched permanently deaf to its window.
    func testTheCtlOverrideIsConsumedByOneApply() throws {
        let pty = try makePTY()
        let session = makeSession(pty: pty)
        session.startRelay()
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        session.applyResolvedGrid()
        XCTAssertEqual(pollGrid(pty, untilCols: 120, rows: 40).cols, 120)

        session.resizeForControl(rows: 50, cols: 132)
        XCTAssertEqual(pollGrid(pty, untilCols: 132, rows: 50).cols, 132, "the override wins its apply")

        // Nothing new offered — the fold alone decides again, and it still holds the client's grid.
        session.applyResolvedGrid()
        XCTAssertEqual(
            pollGrid(pty, untilCols: 120, rows: 40).cols, 120,
            "the override was spent; the contributing set is back in charge",
        )
    }

    /// A redraw jiggle deliberately leaves the PTY one row SHORT while the app re-layouts. If the
    /// applied grid is remembered rather than READ, the next flush sees "resolved size unchanged"
    /// and skips — and the pane stays one row short for the rest of the session.
    ///
    /// Idempotence is therefore a comparison against the live `TIOCGWINSZ`, never against a memo.
    func testAFlushReAssertsTheGridAfterAJiggleLeftItShort() throws {
        let pty = try makePTY()
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let session = makeSession(pty: pty, control: control)
        session.startRelay()

        deliver(control, [
            .resize(cols: 120, rows: 40, pxWidth: 0, pxHeight: 0),
            .ack(seq: 0), // the synchronous flush
        ])
        XCTAssertEqual(pollGrid(pty, untilCols: 120, rows: 40).rows, 40, "the client's grid landed")

        // The first half of the resize dance, left deliberately unfinished — the state a client
        // whose link died mid-jiggle leaves behind.
        let jiggle = try XCTUnwrap(pty.beginRedrawJiggle(), "a 120x40 pty can always shrink a row")
        XCTAssertEqual(jiggle.jiggled.ws_row, 39)
        XCTAssertEqual(pollGrid(pty, untilCols: 120, rows: 39).rows, 39, "the pty is short")

        deliver(control, [.ack(seq: 1)])

        let restored = pollGrid(pty, untilCols: 120, rows: 40)
        XCTAssertEqual(
            restored.rows, 40,
            "the resolved grid re-asserts against the LIVE size, so the short row is repaired",
        )
        XCTAssertEqual(restored.cols, 120)
    }
}
