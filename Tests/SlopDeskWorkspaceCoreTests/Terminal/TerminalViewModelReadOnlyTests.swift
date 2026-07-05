import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - TerminalViewModelReadOnlyTests (E17 ES-E17-1 — the single-seam read-only input gate)

/// Exercises the PURE read-only state + the ``TerminalViewModel/sendInput(_:)`` gate entirely in-memory:
/// no `NSEvent`, no `GhosttySurface`, no window server (the hang-safety rule). Because `sendInput` is the
/// ONE outbound ingress seam (every key / paste / IME / mouse-report / click-to-move byte + the iOS
/// input-bar + the synchronized-input broadcast funnel through it), gating it here proves the whole input
/// surface is blocked — and that inbound ingest is untouched — without driving the renderer.
@MainActor
final class TerminalViewModelReadOnlyTests: XCTestCase {
    // MARK: The input gate (the load-bearing seam)

    /// While read-only, `sendInput` drops the bytes BEFORE the local sink AND the broadcast tap — neither the
    /// host nor the synchronized-input siblings see them. Revert-to-fail: remove the gate and both closures
    /// fire (the un-fixed behavior the `TerminalViewModelTests.testSendInput*` pins).
    func testReadOnlyDropsInputBeforeSinkAndBroadcast() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        var tapped: [Data] = []
        model.inputSink = { sunk.append($0) }
        model.broadcastTap = { tapped.append($0) }

        model.enterReadOnly()
        model.sendInput(Data("blocked".utf8))

        XCTAssertEqual(sunk, [], "read-only drops the byte before inputSink — the host never sees it")
        XCTAssertEqual(tapped, [], "read-only drops the byte before broadcastTap — siblings never see it")
    }

    /// Exiting read-only restores the full funnel (the gate is not a one-way latch). A control proving the
    /// gate is keyed on the flag, not a permanent break — and that the SAME model that dropped now forwards.
    func testExitReadOnlyRestoresInput() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        var tapped: [Data] = []
        model.inputSink = { sunk.append($0) }
        model.broadcastTap = { tapped.append($0) }

        model.enterReadOnly()
        model.sendInput(Data("dropped".utf8))
        model.exitReadOnly()
        model.sendInput(Data("typed".utf8))

        XCTAssertEqual(sunk, [Data("typed".utf8)], "after exit, inputSink forwards again (only the second byte)")
        XCTAssertEqual(tapped, [Data("typed".utf8)], "after exit, broadcastTap forwards again")
    }

    // MARK: Beep (rate-limited — beeps once under a flood)

    /// A read-only input flood beeps ONCE, not per event (a mouse-report flood funnels through `sendInput`).
    /// The injected `beep` seam counts without ringing a real `NSSound`; a wide interval coalesces the burst.
    func testReadOnlyBeepsOnceUnderFlood() {
        let model = TerminalViewModel()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.readOnlyBeepInterval = .seconds(60) // wide window → the whole burst is one beep
        model.inputSink = { _ in XCTFail("read-only must not forward to the host") }

        model.enterReadOnly()
        for _ in 0..<50 { model.sendInput(Data([0x61])) }

        XCTAssertEqual(beeps, 1, "a 50-event read-only flood beeps exactly once (rate-limited, not per event)")
    }

    /// The throttle is INTERVAL-driven, not a one-shot latch: with a zero interval every blocked input beeps
    /// (the monotonic clock advances between calls, so `now - last` is never `< 0`). Proves the rate-limit
    /// reads `readOnlyBeepInterval` rather than beeping at most once for the pane's whole lifetime.
    func testReadOnlyBeepRingsAgainAfterInterval() {
        let model = TerminalViewModel()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.readOnlyBeepInterval = .zero // no coalescing window → every blocked input beeps

        model.enterReadOnly()
        model.sendInput(Data([0x61]))
        model.sendInput(Data([0x62]))
        model.sendInput(Data([0x63]))

        XCTAssertEqual(beeps, 3, "with a zero interval each blocked input rings — the throttle is interval-keyed")
    }

    /// A writable pane never beeps on input (the beep is exclusively the blocked-input cue).
    func testWritablePaneNeverBeeps() {
        let model = TerminalViewModel()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.inputSink = { _ in }

        model.sendInput(Data("hello".utf8))
        XCTAssertEqual(beeps, 0, "a writable pane forwards input and never beeps")
    }

    // MARK: Ingest is untouched (read-only never gates inbound)

    /// Read-only gates OUTBOUND only — inbound host output keeps streaming. `bytesReceived` advances and the
    /// connection still flips to `.connected` on the first chunk while read-only. (The `surface` is nil; the
    /// pure ingest bookkeeping is what we assert — no renderer needed.)
    func testReadOnlyDoesNotGateIngest() {
        let model = TerminalViewModel()
        model.markReconnecting() // → .reconnecting, so the first ingest flips to .connected
        model.enterReadOnly()

        model.ingestOutput(Data("host output while read-only".utf8))

        XCTAssertEqual(model.bytesReceived, 27, "inbound bytes are counted while read-only (ingest is not gated)")
        XCTAssertEqual(model.connectionStatus, .connected, "the first inbound chunk still connects under read-only")
    }

    // MARK: State mirror + transition hook (convergence to one source of truth)

    /// The observable ``readOnlyBadgeActive`` mirror tracks ``isReadOnly`` in lock-step (the `isCopyMode` /
    /// `copyModeBadgeActive` twin) — the keyDown intercept reads the `@ObservationIgnored` flag, the pill
    /// reads the observable mirror.
    func testBadgeMirrorsTheFlag() {
        let model = TerminalViewModel()
        XCTAssertFalse(model.readOnlyBadgeActive, "fresh pane is writable")
        model.enterReadOnly()
        XCTAssertTrue(model.readOnlyBadgeActive, "the observable mirror lights when read-only arms")
        model.exitReadOnly()
        XCTAssertFalse(model.readOnlyBadgeActive, "the mirror clears when read-only disarms")
    }

    /// ``onReadOnlyChanged`` fires with the new value on each real transition (the seam the store uses to keep
    /// `paneReadOnly` in sync so the pill `×`, menu, and palette all converge). Toggle drives true→false→…
    func testTransitionHookFiresWithNewValue() {
        let model = TerminalViewModel()
        var changes: [Bool] = []
        model.onReadOnlyChanged = { changes.append($0) }

        model.toggleReadOnly()
        model.toggleReadOnly()
        XCTAssertEqual(changes, [true, false], "toggle fires the hook with the new value each time")
    }

    /// enter / exit are idempotent: re-entering an already-read-only pane (or exiting a writable one) does NOT
    /// re-fire ``onReadOnlyChanged`` (the guard suppresses the redundant write, so the store's set never churns
    /// and a convergence loop can't form).
    func testEnterExitIdempotentDoNotRefireHook() {
        let model = TerminalViewModel()
        var changes: [Bool] = []
        model.onReadOnlyChanged = { changes.append($0) }

        model.exitReadOnly() // already writable → no-op, no fire
        model.enterReadOnly()
        model.enterReadOnly() // already read-only → no re-fire
        model.exitReadOnly()
        model.exitReadOnly() // already writable → no re-fire

        XCTAssertEqual(changes, [true, false], "only the two real transitions fire the hook")
        XCTAssertFalse(model.isReadOnly)
    }
}
