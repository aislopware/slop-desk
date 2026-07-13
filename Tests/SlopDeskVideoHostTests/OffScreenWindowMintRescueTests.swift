import SlopDeskVideoHost
import XCTest

/// Pins the mint-time rescue for an off-screen window pick (docs/45): the host-windows rail offers
/// MINIMIZED windows (and windows on another Space), but the mint path resolves a hello's
/// requestedWindowID against the ON-SCREEN enumeration — which can never contain either. The rescue
/// must find the target in the FULL enumeration, un-minimize it when that's what hides it, wait for
/// it to land on-screen, and refuse only windows that are truly gone or stay hidden.
final class OffScreenWindowMintRescueTests: XCTestCase {
    /// A stand-in for `SCWindow`: `tag` distinguishes WHICH enumeration an instance came from, so a
    /// test can assert the rescue hands back the freshly on-screen handle vs the full-list one.
    private struct StubWindow: Equatable {
        let id: UInt32
        let tag: String
    }

    /// Mutable call-count / script state shared into the injected effect closures.
    private final class Script: @unchecked Sendable {
        var deminiaturizeCalls = 0
        var onScreenPolls = 0
        var sleeps = 0
        /// Per-poll on-screen answers; polls past the end repeat the last entry.
        var onScreenByPoll: [[StubWindow]?] = [[]]
    }

    private func run(
        windowID: UInt32,
        fullList: [StubWindow]?,
        outcome: DeminiaturizeOutcome,
        pollAttempts: Int = 4,
        script: Script,
    ) async -> StubWindow? {
        await OffScreenWindowMintRescue.run(
            windowID: windowID,
            pollAttempts: pollAttempts,
            fullList: { fullList },
            onScreenList: {
                let poll = script.onScreenPolls
                script.onScreenPolls += 1
                return script.onScreenByPoll[min(poll, script.onScreenByPoll.count - 1)]
            },
            windowIDOf: \.id,
            deminiaturize: { _ in
                script.deminiaturizeCalls += 1
                return outcome
            },
            sleep: { script.sleeps += 1 },
        )
    }

    /// A window in NEITHER enumeration is closed — the rescue must refuse (nil) without ever
    /// touching AX, so the caller's terminal `muxNoWindow` refusal stands.
    func testClosedWindowRefusesWithoutTouchingAX() async {
        let script = Script()
        let got = await run(
            windowID: 7,
            fullList: [StubWindow(id: 9, tag: "full")],
            outcome: .restoring,
            script: script,
        )
        XCTAssertNil(got)
        XCTAssertEqual(script.deminiaturizeCalls, 0)
        XCTAssertEqual(script.sleeps, 0)
    }

    /// A failed FULL enumeration (window-server error) must also refuse, not crash or spin.
    func testFullEnumerationFailureRefuses() async {
        let script = Script()
        let got = await run(windowID: 7, fullList: nil, outcome: .restoring, script: script)
        XCTAssertNil(got)
        XCTAssertEqual(script.deminiaturizeCalls, 0)
    }

    /// A window on ANOTHER SPACE is off-screen but NOT minimized — SCK's desktop-independent filter
    /// captures it where it lives, so the rescue mints from the full-list handle immediately,
    /// with zero polling.
    func testOtherSpaceWindowMintsInPlaceWithoutPolling() async {
        let script = Script()
        let target = StubWindow(id: 7, tag: "full")
        let got = await run(windowID: 7, fullList: [target], outcome: .notMinimized, script: script)
        XCTAssertEqual(got, target)
        XCTAssertEqual(script.deminiaturizeCalls, 1)
        XCTAssertEqual(script.onScreenPolls, 0)
        XCTAssertEqual(script.sleeps, 0)
    }

    /// An AX failure on a minimized window means it STAYS hidden — minting would stream black, so
    /// the rescue refuses and the client falls back to the picker.
    func testAXFailureRefuses() async {
        let script = Script()
        let got = await run(
            windowID: 7,
            fullList: [StubWindow(id: 7, tag: "full")],
            outcome: .failed,
            script: script,
        )
        XCTAssertNil(got)
        XCTAssertEqual(script.onScreenPolls, 0)
    }

    /// The happy path: un-minimize lands, the window appears in the on-screen list after a couple of
    /// polls, and the rescue returns the freshly ON-SCREEN handle (not the stale full-list one).
    func testMinimizedWindowReturnsOnScreenHandleOnceItLands() async {
        let script = Script()
        script.onScreenByPoll = [
            [],
            [StubWindow(id: 9, tag: "onscreen")],
            [StubWindow(id: 9, tag: "onscreen"), StubWindow(id: 7, tag: "onscreen")],
        ]
        let got = await run(
            windowID: 7,
            fullList: [StubWindow(id: 7, tag: "full")],
            outcome: .restoring,
            script: script,
        )
        XCTAssertEqual(got, StubWindow(id: 7, tag: "onscreen"))
        XCTAssertEqual(script.onScreenPolls, 3)
        XCTAssertEqual(script.sleeps, 3, "one sleep before every poll — the AX write needs time to paint")
    }

    /// A restore slower than the poll budget must still MINT (from the full-list handle — the
    /// capturer re-resolves off-screen windows itself), never refuse: the un-minimize already
    /// succeeded, so the window IS coming back.
    func testSlowRestoreFallsBackToFullListHandle() async {
        let script = Script()
        let target = StubWindow(id: 7, tag: "full")
        let got = await run(windowID: 7, fullList: [target], outcome: .restoring, pollAttempts: 3, script: script)
        XCTAssertEqual(got, target)
        XCTAssertEqual(script.onScreenPolls, 3)
        XCTAssertEqual(script.sleeps, 3)
    }

    /// A failed on-screen re-enumeration mid-poll (transient window-server error) keeps polling
    /// instead of aborting the rescue.
    func testEnumerationHiccupMidPollKeepsPolling() async {
        let script = Script()
        script.onScreenByPoll = [nil, [StubWindow(id: 7, tag: "onscreen")]]
        let got = await run(
            windowID: 7,
            fullList: [StubWindow(id: 7, tag: "full")],
            outcome: .restoring,
            script: script,
        )
        XCTAssertEqual(got, StubWindow(id: 7, tag: "onscreen"))
        XCTAssertEqual(script.onScreenPolls, 2)
    }
}
