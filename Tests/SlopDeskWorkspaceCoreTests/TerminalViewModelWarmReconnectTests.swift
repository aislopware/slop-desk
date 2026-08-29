import Foundation
import SlopDeskClient
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

/// Warm-reconnect wipe gating (post-audit replay-core fix, TerminalViewModel:1879).
///
/// With `SLOPDESK_DETACH_ENABLED` default-ON, a transient link drop detaches the host shell and
/// the reconnect REATTACHES the same live session (PATH A), replaying only the un-acked tail —
/// the host never re-sends the surviving screen/scrollback. `markReconnecting()` used to arm the
/// one-shot fresh-session wipe UNCONDITIONALLY (a stale "no mux resume" assumption), so the first
/// post-reconnect output RIS-wiped the whole framebuffer AND replay ring: every network blip
/// erased the terminal even though the shell survived byte-exactly.
///
/// The reliable signal is the client's ``SlopDeskClient/SessionResumeOutcome``. DERIVING it is
/// `slopdesk-clientsession`'s — a PATH-A reattach continues the retained seq stream past the
/// presented `lastReceivedSeq`, a fresh shell restarts at 1 — and that derivation has its own tests
/// where the seqs are the input. What is left here, and what these tests drive, is the half the pump
/// owns: given a verdict, does `observe(client:)` consume the one-shot wipe or preserve it, and does
/// it fire the toast exactly once and only after a DROP. So the double STATES the verdict; a suite
/// that re-derived it here would be pinning a rule twice and in the weaker language.
@MainActor
final class TerminalViewModelWarmReconnectTests: XCTestCase {
    /// RIS — Reset to Initial State (`ESC c`), the fresh-session wipe prefix.
    private static let ris = Data([0x1B, 0x63])

    /// A warm reconnect that lands on a PATH-A reattach (the seq stream CONTINUES) must NOT
    /// consume the fresh-session wipe: the surviving screen + replay ring stay intact.
    /// REVERT-TO-FAIL: the unconditional `pendingFreshSessionReset = true` in
    /// `markReconnecting()` (with no observe-side resolution) feeds RIS + clears the ring here.
    func testWarmReattachDoesNotWipeSurvivingScreenAndRing() async throws {
        let driver = FakePaneDriver()
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        // Pre-drop history paints and is retained in the replay ring.
        let history = Data("$ ls\nREADME.md\n".utf8)
        driver.deliverOutput(history)
        await waitUntil { surface.writes.contains(history) }
        XCTAssertEqual(model.ringByteCount, history.count, "precondition: history retained in the ring")
        surface.writes.removeAll()

        // Transient network blip: the reconnect campaign begins (ConnectionViewModel folds
        // `.disconnected` → markReconnecting()).
        model.markReconnecting()

        // The reconnect lands on PATH A: the client presents lastSeq=1 and the host reattaches
        // the SAME shell — nothing is replayed, and the SIGWINCH prompt repaint continues the
        // retained seq stream.
        driver.resumeOutcome = .resumedSession
        try await client.connect(host: "h", port: 1)
        let repaint = Data("$ ".utf8)
        driver.deliverOutput(repaint)
        await waitUntil { surface.writes.contains(repaint) }

        XCTAssertFalse(
            surface.writes.contains(Self.ris),
            "a PATH-A reattach resumes the SAME shell — wiping would erase a screen the host never re-sends",
        )
        XCTAssertEqual(
            model.ringByteCount, history.count + repaint.count,
            "the replay ring must keep the pre-drop history across a warm reattach (tab-switch replay depends on it)",
        )

        await client.close()
    }

    /// The reconnect landing on a FRESH shell (the seq stream RESTARTS at 1) must still wipe —
    /// the dead session's framebuffer would otherwise graft under the new prompt. Pins that the
    /// warm-reattach fix does not disarm the wipe for the genuinely-fresh case.
    func testReconnectOntoFreshShellStillWipes() async throws {
        let driver = FakePaneDriver()
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        let history = Data("$ old-session\n".utf8)
        driver.deliverOutput(history)
        await waitUntil { surface.writes.contains(history) }
        surface.writes.removeAll()

        model.markReconnecting()

        // The reconnect lands on PATH B/C: the host spawned a FRESH shell whose ReplayBuffer
        // restarts the stream at seq 1.
        driver.resumeOutcome = .freshShell
        try await client.connect(host: "h", port: 1)
        let freshPrompt = Data("fresh-$ ".utf8)
        driver.deliverOutput(freshPrompt)
        await waitUntil { surface.writes.contains(freshPrompt) }

        XCTAssertEqual(
            surface.writes.first, Self.ris,
            "a fresh host shell must still RIS-wipe the dead session's framebuffer before painting",
        )
        XCTAssertEqual(
            model.ringByteCount, freshPrompt.count,
            "the ring must hold only the fresh session's bytes after the wipe",
        )

        await client.close()
    }

    // MARK: - C8 improvement 1: fresh-vs-resumed toast signal (onResumeOutcomeResolved)

    /// A warm PATH-A reattach after a DROP fires `onResumeOutcomeResolved(.resumedSession)` exactly once — the
    /// signal the store turns into a "Reattached (session preserved)" toast. REVERT-TO-FAIL: without the
    /// `notifyResumeOutcome` call in `resolveResumeOutcomeIfNeeded` the callback never fires.
    func testResumeOutcomeCallbackFiresResumedAfterReconnect() async throws {
        let driver = FakePaneDriver()
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        var captured: [SlopDeskClient.SessionResumeOutcome] = []
        model.onResumeOutcomeResolved = { captured.append($0) }
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        let history = Data("$ ls\n".utf8)
        driver.deliverOutput(history)
        await waitUntil { surface.writes.contains(history) }
        XCTAssertTrue(captured.isEmpty, "the initial connect must not fire the reconnect toast")

        // A genuine drop → reconnect that REATTACHES the same shell.
        model.markReconnecting()
        driver.resumeOutcome = .resumedSession
        try await client.connect(host: "h", port: 1)
        let repaint = Data("$ ".utf8)
        driver.deliverOutput(repaint)
        await waitUntil { !captured.isEmpty }

        XCTAssertEqual(captured, [.resumedSession], "a warm reattach fires exactly one .resumedSession signal")
        await client.close()
    }

    /// A reconnect landing on a FRESH shell (the seq stream restarts at 1) fires
    /// `onResumeOutcomeResolved(.freshShell)` — the store's "Reconnected (fresh shell — previous session ended)"
    /// cue. The two determinate verdicts must be distinguishable, so this pins the fresh side.
    func testResumeOutcomeCallbackFiresFreshAfterReconnect() async throws {
        let driver = FakePaneDriver()
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        var captured: [SlopDeskClient.SessionResumeOutcome] = []
        model.onResumeOutcomeResolved = { captured.append($0) }
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        driver.deliverOutput(Data("$ old\n".utf8))
        await waitUntil { surface.writes.contains(Data("$ old\n".utf8)) }

        model.markReconnecting()
        driver.resumeOutcome = .freshShell
        try await client.connect(host: "h", port: 1)
        driver.deliverOutput(Data("fresh-$ ".utf8))
        await waitUntil { !captured.isEmpty }

        XCTAssertEqual(captured, [.freshShell], "a fresh host shell fires exactly one .freshShell signal")
        await client.close()
    }

    /// A FRESH CONNECT (`reset()`, i.e. first launch / a deliberate ⇧⌘R) resolves `.freshShell` and arms the
    /// wipe, but must fire NO toast — the "previous session ended" cue is for UNEXPECTED drops only, never a
    /// launch surprise. REVERT-TO-FAIL: dropping the `resumeOutcomeNotifiable` gate makes this fire a spurious
    /// toast on every fresh connect.
    func testResumeOutcomeCallbackSuppressedOnFreshConnect() async throws {
        let driver = FakePaneDriver()
        let client = SlopDeskClient(driver: driver)
        try await client.connect(host: "h", port: 1)

        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        var captured: [SlopDeskClient.SessionResumeOutcome] = []
        model.onResumeOutcomeResolved = { captured.append($0) }
        let pump = Task { await model.observe(client: client) }
        defer { pump.cancel() }

        // reset() is the fresh-connect boundary (the real ConnectionViewModel.connect() calls it): it arms the
        // wipe but clears the notify flag, so the resolved .freshShell verdict must stay silent.
        model.reset()
        driver.resumeOutcome = .freshShell
        let prompt = Data("fresh-$ ".utf8)
        driver.deliverOutput(prompt)
        await waitUntil { surface.writes.contains(prompt) }

        XCTAssertTrue(captured.isEmpty, "a fresh connect (reset) resolves .freshShell but must fire no toast")
        await client.close()
    }

    // MARK: - Helpers

    /// Polls `condition` (≤ ~5 s) while suspending the test method so the MainActor pump runs.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class RecordingSurface: TerminalSurface, @unchecked Sendable {
        var writes: [Data] = []
        func feed(_ bytes: Data) { writes.append(bytes) }
        func feedBatch(_ chunks: ArraySlice<Data>) { writes.append(contentsOf: chunks) }
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
        var onWrite: ((Data) -> Void)?
    }
}
