import XCTest
import AislopdeskProtocol
@testable import AislopdeskHost

/// WF11: the host-side OSC 133 command-status sniffer. Deterministic + HostServer-free — a pure
/// byte-stream state machine with an INJECTED clock so the C→D duration is exact. Mirrors the
/// `HostTitleBellSniffer` test discipline (split-boundary equivalence + non-destructive forwarding).
final class HostCommandStatusSnifferTests: XCTestCase {

    // A test clock the sniffer reads on each `C`/`D`. `advance(_:)` moves it forward so a
    // `C … D` pair has a known duration, no wall-clock sleep.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return now }
        func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock() }
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// OSC 133 ; <mark> BEL.
    private func osc133(_ mark: String) -> [UInt8] { bytes("\u{1B}]133;\(mark)\u{07}") }

    // MARK: C → D: running then idle with measured duration + exit code

    func testCStartedThenDFinishedWithExitAndDuration() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)

        // C: command started → .running.
        let onC = sniffer.observe(osc133("C"))
        XCTAssertEqual(onC, [.commandStatus(.running)])

        // 12 seconds elapse on the host clock between C and D.
        clock.advance(12)

        // D;0: command finished, exit 0 → .idle with the measured 12_000 ms.
        let onD = sniffer.observe(osc133("D;0"))
        XCTAssertEqual(onD, [.commandStatus(.idle(exitCode: 0, durationMS: 12_000))])
    }

    func testQuickCommandSubSecondDuration() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(0.3) // 300 ms
        XCTAssertEqual(sniffer.observe(osc133("D;0")),
                       [.commandStatus(.idle(exitCode: 0, durationMS: 300))])
    }

    func testNonZeroExitCodeParsed() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(1)
        XCTAssertEqual(sniffer.observe(osc133("D;130")),
                       [.commandStatus(.idle(exitCode: 130, durationMS: 1_000))])
    }

    func testDWithoutExitCodeYieldsNilExit() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(2)
        // Bare `D` (no exit field) → nil exit, 2_000 ms.
        XCTAssertEqual(sniffer.observe(osc133("D")),
                       [.commandStatus(.idle(exitCode: nil, durationMS: 2_000))])
    }

    func testDExtraKeyValueFieldsTolerated() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        _ = sniffer.observe(osc133("C"))
        clock.advance(1)
        // iTerm2/FinalTerm sometimes append `;aid=...` etc. — the exit (field 2) still parses.
        XCTAssertEqual(sniffer.observe(osc133("D;0;aid=123")),
                       [.commandStatus(.idle(exitCode: 0, durationMS: 1_000))])
    }

    // MARK: D without a matching C is ignored (the first-prompt phantom)

    func testDWithoutPrecedingCIsIgnored() {
        let sniffer = HostCommandStatusSniffer(clock: { Date() })
        // The very first precmd emits D;0 for a command that never started — must be a no-op.
        XCTAssertEqual(sniffer.observe(osc133("D;0")), [])
    }

    func testAandBmarksAreNotSurfaced() {
        let sniffer = HostCommandStatusSniffer(clock: { Date() })
        XCTAssertEqual(sniffer.observe(osc133("A")), [], "prompt-start A is not a command status")
        XCTAssertEqual(sniffer.observe(osc133("B")), [], "command-line-start B is not a command status")
    }

    // MARK: Full prompt cycle (A→C→D→A) yields exactly running then idle

    func testFullPromptCycleYieldsRunningThenIdle() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        var out: [WireMessage] = []
        // precmd of an empty first prompt: D;0 (ignored) then A (ignored).
        out += sniffer.observe(osc133("D;0"))
        out += sniffer.observe(osc133("A"))
        // user runs a command: preexec C.
        out += sniffer.observe(osc133("C"))
        clock.advance(11)
        // command done: precmd D;0 then A.
        out += sniffer.observe(osc133("D;0"))
        out += sniffer.observe(osc133("A"))
        XCTAssertEqual(out, [
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 11_000)),
        ])
    }

    // MARK: Split-boundary equivalence — same events feeding one byte at a time

    func testSplitAtEveryByteBoundaryProducesIdenticalEvents() {
        // Build a stream with a full C → (advance) → D cycle. Because the duration is read from
        // the clock at the moment each mark COMPLETES, advance the clock once between feeding the
        // C bytes and the D bytes — identical to the whole-chunk case.
        let cBytes = osc133("C")
        let dBytes = osc133("D;7")

        // Whole-chunk reference.
        let refClock = TestClock()
        let ref = HostCommandStatusSniffer(clock: refClock.date)
        var reference: [WireMessage] = []
        reference += ref.observe(cBytes)
        refClock.advance(5)
        reference += ref.observe(dBytes)

        // One byte at a time, with the SAME single advance between the two marks.
        let splitClock = TestClock()
        let split = HostCommandStatusSniffer(clock: splitClock.date)
        var got: [WireMessage] = []
        for b in cBytes { got += split.observe([b]) }
        splitClock.advance(5)
        for b in dBytes { got += split.observe([b]) }

        XCTAssertEqual(got, reference)
        XCTAssertEqual(got, [
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 7, durationMS: 5_000)),
        ])
    }

    // MARK: ST (ESC \) terminator works as well as BEL

    func testSTTerminatorRecognized() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        // ESC ] 133 ; C  ESC \   (ST instead of BEL)
        let c = Array("\u{1B}]133;C\u{1B}\\".utf8)
        XCTAssertEqual(sniffer.observe(c), [.commandStatus(.running)])
        clock.advance(1)
        let d = Array("\u{1B}]133;D;0\u{1B}\\".utf8)
        XCTAssertEqual(sniffer.observe(d), [.commandStatus(.idle(exitCode: 0, durationMS: 1_000))])
    }

    // MARK: Interleaved with ordinary output + a title OSC (not a 133 mark)

    func testIgnoresNon133OSCAndPlainContent() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        // A title OSC (0;…) + plain prompt text → nothing.
        let preamble = Array("\u{1B}]0;my title\u{07}user@host % ".utf8)
        XCTAssertEqual(sniffer.observe(preamble), [])
        // Then a real C.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
    }

    // MARK: Two commands back to back (state resets correctly)

    func testTwoSequentialCommandsEachMeasuredIndependently() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        // First command: 3s.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(3)
        XCTAssertEqual(sniffer.observe(osc133("D;0")),
                       [.commandStatus(.idle(exitCode: 0, durationMS: 3_000))])
        // Second command: 7s — runningSince must have been cleared + reset.
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)])
        clock.advance(7)
        XCTAssertEqual(sniffer.observe(osc133("D;1")),
                       [.commandStatus(.idle(exitCode: 1, durationMS: 7_000))])
    }

    /// R9 #4 (security): a `133;C/D` mark embedded inside a DCS/APC string body must NOT produce a phantom
    /// command-status — a conformant terminal swallows the string. So a hostile remote program cannot fake
    /// a running/idle badge (with an attacker-chosen exit code + duration).
    func testStringSequencesSwallowEmbeddedCommandStatus() {
        let clock = TestClock()
        let sniffer = HostCommandStatusSniffer(clock: clock.date)
        // `ESC P` (DCS) … embedded `ESC]133;C BEL` … `ESC \` (ST) → swallowed, no phantom .running.
        let dcsSpoof = bytes("\u{1B}P\u{1B}]133;C\u{07}\u{1B}\\")
        XCTAssertEqual(sniffer.observe(dcsSpoof), [], "an OSC 133 embedded in a DCS string must not fire a status")
        // A REAL 133;C after the swallowed string still fires (clean resync).
        XCTAssertEqual(sniffer.observe(osc133("C")), [.commandStatus(.running)],
                       "a real mark after the swallowed string still fires")
    }
}
