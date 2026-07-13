import SlopDeskVideoHost
import XCTest

/// Pins the mint-time rescue for an off-screen window pick (docs/45): the host-windows rail offers
/// MINIMIZED windows (and windows on another Space), but the mint path resolves a hello's
/// requestedWindowID against the ON-SCREEN enumeration — which can never contain either. The rescue
/// must find the target in the FULL enumeration, un-minimize it when that's what hides it, and wait
/// for the restore to SETTLE before handing back a handle: capture size is locked from the minted
/// handle's frame, and the Dock restore reports intermediate animation frames with
/// `isOnScreen == true` (HW-measured 62×136 → 757×423 → 656×422 over ~550 ms), so a first-sighting
/// mint crops the stream to a top-left sliver of the real window.
final class OffScreenWindowMintRescueTests: XCTestCase {
    /// A stand-in for `SCWindow`: `frame` drives the settle gate; `tag` distinguishes WHICH
    /// enumeration/poll an instance came from, so a test can assert the rescue hands back the
    /// settled handle and not a stale one.
    private struct StubWindow: Equatable {
        let id: UInt32
        let frame: String
        let tag: String
    }

    /// Mutable call-count / script state shared into the injected effect closures. Scripted answers
    /// past the end of an array repeat the last entry.
    private final class Script: @unchecked Sendable {
        var deminiaturizeCalls = 0
        var fullCalls = 0 // includes the rescue's initial target lookup
        var onScreenPolls = 0
        var sleeps = 0
        var fullByCall: [[StubWindow]?] = [[]]
        var onScreenByPoll: [[StubWindow]?] = [[]]

        func next(_ script: [[StubWindow]?], _ index: Int) -> [StubWindow]? {
            script[min(index, script.count - 1)]
        }
    }

    private func run(
        windowID: UInt32,
        outcome: DeminiaturizeOutcome,
        pollAttempts: Int = 6,
        script: Script,
    ) async -> StubWindow? {
        await OffScreenWindowMintRescue.run(
            windowID: windowID,
            pollAttempts: pollAttempts,
            fullList: {
                let call = script.fullCalls
                script.fullCalls += 1
                return script.next(script.fullByCall, call)
            },
            onScreenList: {
                let poll = script.onScreenPolls
                script.onScreenPolls += 1
                return script.next(script.onScreenByPoll, poll)
            },
            windowIDOf: \.id,
            frameOf: \.frame,
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
        script.fullByCall = [[StubWindow(id: 9, frame: "f", tag: "full")]]
        let got = await run(windowID: 7, outcome: .restoring, script: script)
        XCTAssertNil(got)
        XCTAssertEqual(script.deminiaturizeCalls, 0)
        XCTAssertEqual(script.sleeps, 0)
    }

    /// A failed FULL enumeration (window-server error) must also refuse, not crash or spin.
    func testFullEnumerationFailureRefuses() async {
        let script = Script()
        script.fullByCall = [nil]
        let got = await run(windowID: 7, outcome: .restoring, script: script)
        XCTAssertNil(got)
        XCTAssertEqual(script.deminiaturizeCalls, 0)
    }

    /// An AX failure on a minimized window means it STAYS hidden — minting would stream black, so
    /// the rescue refuses and the client falls back to the picker.
    func testAXFailureRefuses() async {
        let script = Script()
        script.fullByCall = [[StubWindow(id: 7, frame: "f", tag: "full")]]
        let got = await run(windowID: 7, outcome: .failed, script: script)
        XCTAssertNil(got)
        XCTAssertEqual(script.onScreenPolls, 0)
        XCTAssertEqual(script.sleeps, 0)
    }

    /// `.notMinimized` (other Space — or a restore that was ALREADY animating when the hello raced
    /// it: `AXMinimized` flips false at animation START): the handle stays off the on-screen list,
    /// so the settle gate runs on the FULL enumeration — two consecutive polls must agree.
    func testOtherSpaceWindowSettlesOnFullList() async {
        let script = Script()
        let settled = StubWindow(id: 7, frame: "656x422", tag: "full-settled")
        script.fullByCall = [
            [StubWindow(id: 7, frame: "656x422", tag: "full-initial")], // target lookup
            [StubWindow(id: 7, frame: "656x422", tag: "full-poll-1")],
            [settled],
        ]
        let got = await run(windowID: 7, outcome: .notMinimized, script: script)
        XCTAssertEqual(got, settled)
        XCTAssertEqual(script.deminiaturizeCalls, 1)
        XCTAssertEqual(script.onScreenPolls, 0)
        XCTAssertEqual(script.sleeps, 2, "stable frame → two polls settle it")
    }

    /// `.notMinimized` mid-animation: intermediate frames must NOT be minted — the gate waits until
    /// two consecutive full-list polls agree.
    func testRacedRestoreWaitsForFullListFrameToSettle() async {
        let script = Script()
        let settled = StubWindow(id: 7, frame: "656x422", tag: "full-settled")
        script.fullByCall = [
            [StubWindow(id: 7, frame: "111x204", tag: "full-initial")],
            [StubWindow(id: 7, frame: "300x280", tag: "full-poll-1")],
            [StubWindow(id: 7, frame: "656x422", tag: "full-poll-2")],
            [settled],
        ]
        let got = await run(windowID: 7, outcome: .notMinimized, script: script)
        XCTAssertEqual(got, settled)
        XCTAssertEqual(script.sleeps, 3)
    }

    /// The minimized happy path: un-minimize lands, the window appears on-screen, and the rescue
    /// returns the handle only once two consecutive polls report the SAME frame — never the
    /// first sighting (its frame is usually a mid-genie sliver).
    func testMinimizedWindowSettlesOnOnScreenList() async {
        let script = Script()
        let settled = StubWindow(id: 7, frame: "656x422", tag: "onscreen-settled")
        script.fullByCall = [[StubWindow(id: 7, frame: "656x422", tag: "full")]]
        script.onScreenByPoll = [
            [],
            [StubWindow(id: 7, frame: "62x136", tag: "onscreen-genie")],
            [StubWindow(id: 7, frame: "757x423", tag: "onscreen-overshoot")],
            [StubWindow(id: 7, frame: "656x422", tag: "onscreen-first-settled")],
            [settled],
        ]
        let got = await run(windowID: 7, outcome: .restoring, script: script)
        XCTAssertEqual(got, settled)
        XCTAssertEqual(script.onScreenPolls, 5)
        XCTAssertEqual(script.sleeps, 5, "one sleep before every poll — the AX write needs time to paint")
    }

    /// A restore that never stabilizes within the poll budget must still MINT — from the LAST
    /// sighting (closest to settled), never refuse: the un-minimize already succeeded, so the
    /// window IS coming back.
    func testNeverStabilizingRestoreMintsFromLastSighting() async {
        let script = Script()
        let last = StubWindow(id: 7, frame: "frame-3", tag: "onscreen-last")
        script.fullByCall = [[StubWindow(id: 7, frame: "f", tag: "full")]]
        script.onScreenByPoll = [
            [StubWindow(id: 7, frame: "frame-1", tag: "onscreen-1")],
            [StubWindow(id: 7, frame: "frame-2", tag: "onscreen-2")],
            [last],
        ]
        let got = await run(windowID: 7, outcome: .restoring, pollAttempts: 3, script: script)
        XCTAssertEqual(got, last)
        XCTAssertEqual(script.sleeps, 3)
    }

    /// A restore slower than the whole poll budget (never sighted on-screen) still mints from the
    /// full-list handle — its frame is the pre-minimize one, which is what the window restores to.
    func testNeverLandingRestoreFallsBackToFullListHandle() async {
        let script = Script()
        let target = StubWindow(id: 7, frame: "656x422", tag: "full")
        script.fullByCall = [[target]]
        let got = await run(windowID: 7, outcome: .restoring, pollAttempts: 3, script: script)
        XCTAssertEqual(got, target)
        XCTAssertEqual(script.onScreenPolls, 3)
    }

    /// A failed on-screen re-enumeration mid-poll (transient window-server error) keeps polling
    /// instead of aborting the rescue — and does not count as a frame sighting.
    func testEnumerationHiccupMidPollKeepsPolling() async {
        let script = Script()
        let settled = StubWindow(id: 7, frame: "656x422", tag: "onscreen-settled")
        script.fullByCall = [[StubWindow(id: 7, frame: "f", tag: "full")]]
        script.onScreenByPoll = [
            nil,
            [StubWindow(id: 7, frame: "656x422", tag: "onscreen-1")],
            [settled],
        ]
        let got = await run(windowID: 7, outcome: .restoring, script: script)
        XCTAssertEqual(got, settled)
        XCTAssertEqual(script.onScreenPolls, 3)
    }
}
