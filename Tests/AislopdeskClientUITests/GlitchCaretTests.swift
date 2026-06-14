import AislopdeskClient
import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Glitch-caret predictive-echo v1 (docs/12 §B → docs/17 §2.4, docs/31 #3): the gate
/// matrix (flag / RTT hysteresis / alt-screen / connection), the OUT-side keystroke
/// classification (printable arms, backspace retires, control/paste clears), the
/// IN-side reconciliation (ANY ingest hides), the expiry backstop, and lifecycle
/// clears. All headless — the caret's only observable output is `glitchCaretVisible`.
@MainActor
final class GlitchCaretTests: XCTestCase {
    private let a = Data([UInt8(ascii: "a")])
    private let backspace = Data([0x7F])
    private let carriageReturn = Data([0x0D])

    /// A connected model with the caret in `force` mode and a zero glitch window
    /// (the echo would win the race otherwise) + a short test expiry.
    private func makeModel(
        mode: TerminalViewModel.GlitchCaretMode = .forced,
        expiryMS: Int = 60000,
    ) -> TerminalViewModel {
        let model = TerminalViewModel()
        model.glitchCaretMode = mode
        model.glitchWindow = .milliseconds(0)
        model.glitchExpiry = .milliseconds(expiryMS)
        model.handle(.reconnected(sessionID: UUID(), resumeFromSeq: 0)) // → .connected
        return model
    }

    /// Polls the main actor until `condition` holds or the timeout lapses.
    private func waitUntil(
        timeoutMS: Int = 2000,
        _ condition: () -> Bool,
    ) async -> Bool {
        var elapsed = 0
        while !condition(), elapsed < timeoutMS {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 10
        }
        return condition()
    }

    /// Asserts the caret stays hidden over a settle window (negative cases).
    private func assertStaysHidden(
        _ model: TerminalViewModel,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        _ = await waitUntil(timeoutMS: 150) { model.glitchCaretVisible }
        XCTAssertFalse(model.glitchCaretVisible, message, file: file, line: line)
    }

    // MARK: Core arm → show → reconcile

    func testForcedModeShowsCaretAndAnyIngestHidesIt() async {
        let model = makeModel()
        model.sendInput(a)
        let shown = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(shown, "printable keystroke with no echo shows the caret after the window")

        model.ingestOutput(Data("a".utf8)) // the echo (any output) is the ground truth
        XCTAssertFalse(model.glitchCaretVisible, "ANY ingest hides the caret synchronously")

        // Re-arms cleanly for the next keystroke.
        model.sendInput(a)
        let shownAgain = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(shownAgain, "pending state fully reset — the caret re-arms")
    }

    func testOffModeNeverShows() async {
        let model = makeModel(mode: .off)
        model.sendInput(a)
        await assertStaysHidden(model, "off is OFF")
    }

    func testNotConnectedNeverShows() async {
        let model = TerminalViewModel() // .idle — never connected
        model.glitchCaretMode = .forced
        model.glitchWindow = .milliseconds(0)
        model.sendInput(a)
        await assertStaysHidden(model, "no host to echo — no caret while not connected")
    }

    // MARK: RTT gate + hysteresis

    func testRTTGateMatrixWithHysteresis() async {
        let model = makeModel(mode: .rttGated)

        // Below the on-threshold: gate closed.
        model.handle(.rtt(milliseconds: 10))
        model.sendInput(a)
        await assertStaysHidden(model, "RTT 10ms < on-threshold 30ms — gate closed")

        // Above the on-threshold: gate opens.
        model.handle(.rtt(milliseconds: 50))
        model.sendInput(a)
        let openShown = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(openShown, "RTT 50ms — gate open")

        // Between off (20) and on (30): hysteresis keeps the gate OPEN.
        model.ingestOutput(Data("echo".utf8))
        model.handle(.rtt(milliseconds: 25))
        model.sendInput(a)
        let hysteresisShown = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(hysteresisShown, "RTT 25ms in the hysteresis band — still armed")

        // Below the off-threshold: gate closes.
        model.ingestOutput(Data("echo".utf8))
        model.handle(.rtt(milliseconds: 10))
        model.sendInput(a)
        await assertStaysHidden(model, "RTT 10ms < off-threshold 20ms — gate closed again")
    }

    // MARK: Alt-screen gate (TerminalModeTracker fed in ingestPass)

    func testAltScreenSuppressesCaret() async {
        let model = makeModel()
        model.ingestOutput(Data("\u{1B}[?1049h".utf8)) // vim/Claude Code enters alt-screen
        model.sendInput(a)
        await assertStaysHidden(model, "alt-screen TUIs own their echo — caret off")

        model.ingestOutput(Data("\u{1B}[?1049l".utf8)) // back to the shell prompt
        model.sendInput(a)
        let rearmed = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(rearmed, "shellPrompt — armed again")
    }

    // MARK: OUT-side classification

    func testBackspaceRetiresPendingKeystroke() async {
        let model = makeModel()
        model.glitchWindow = .milliseconds(40) // give the BS time to retire the 'a'
        model.sendInput(a)
        model.sendInput(backspace)
        await assertStaysHidden(model, "backspace retired the only pending keystroke")
    }

    func testCarriageReturnClearsPending() async {
        let model = makeModel()
        model.glitchWindow = .milliseconds(40)
        model.sendInput(a)
        model.sendInput(carriageReturn)
        await assertStaysHidden(model, "CR is a state change we don't model — cleared")
    }

    func testMultiBytePasteClearsPending() async {
        let model = makeModel()
        model.glitchWindow = .milliseconds(40)
        model.sendInput(a)
        model.sendInput(Data("pasted text".utf8))
        await assertStaysHidden(model, "paste / IME / escape sequences clear all pending")
    }

    // MARK: Expiry backstop (non-echoing prompts: stty -echo, read -s)

    func testExpiryHidesCaretWithoutAnyEcho() async {
        let model = makeModel(expiryMS: 80)
        model.sendInput(a)
        let shown = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(shown)
        let hidden = await waitUntil { !model.glitchCaretVisible }
        XCTAssertTrue(hidden, "expiry force-hides a caret no echo ever answers")
    }

    // MARK: Session-boundary tracker reset (review round)

    func testDropWhileInAltScreenDoesNotDisarmTheNewSession() async {
        let model = makeModel()
        model.ingestOutput(Data("\u{1B}[?1049h".utf8)) // old session: inside vim
        model.markReconnecting() // link drops while in alt-screen
        model.handle(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
        model.ingestOutput(Data("fresh shell $ ".utf8)) // new session: plain prompt
        model.sendInput(a)
        let shown = await waitUntil { model.glitchCaretVisible }
        XCTAssertTrue(shown, "the dead session's .altScreen latch must not survive the reconnect")
    }

    func testDropMidStringSequenceDoesNotSwallowNewSessionMarkers() async {
        let model = makeModel()
        model.ingestOutput(Data("\u{1B}Punterminated dcs body".utf8)) // drop mid-DCS
        model.markReconnecting()
        model.handle(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
        // The new session autostarts a TUI: the tracker must SEE this alt-screen enter
        // (a stale .stringConsume would swallow it and let the caret arm inside the TUI).
        model.ingestOutput(Data("\u{1B}[?1049h".utf8))
        model.sendInput(a)
        await assertStaysHidden(model, "alt-screen in the NEW session is tracked from clean state")
    }

    // MARK: Lifecycle clears

    func testReconnectExitAndResetClearTheCaret() async {
        for tearDown in [
            { (model: TerminalViewModel) in model.markReconnecting() },
            { (model: TerminalViewModel) in model.handle(.exit(code: 0)) },
            { (model: TerminalViewModel) in model.handle(.disconnected(reason: "drop")) },
            { (model: TerminalViewModel) in model.reset() },
        ] {
            let model = makeModel()
            model.sendInput(a)
            let shown = await waitUntil { model.glitchCaretVisible }
            XCTAssertTrue(shown)
            tearDown(model)
            XCTAssertFalse(model.glitchCaretVisible, "lifecycle transition hides the caret")
        }
    }
}
