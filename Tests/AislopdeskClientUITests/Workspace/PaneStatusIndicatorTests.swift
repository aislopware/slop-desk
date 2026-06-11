import XCTest
@testable import AislopdeskClient
@testable import AislopdeskClientUI
import AislopdeskTransport
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the per-pane status presentation (research B1) — the pure ``PaneConnectionStatus`` derivation
/// that BOTH the pane header (``PaneChromeView``) and the sidebar rail (``TabSidebarView``) render from,
/// plus the ``ConnectionViewModel`` reconnect-progress → status transitions that surface the WF3 backoff.
///
/// These are the load-bearing seams: the WF3 timeout + capped-exponential reconnect work is otherwise
/// invisible (it only logged), so the tests prove that a dead-after-connect host now walks
/// `.reconnecting(n)` → `.unreachable` and that the colour/label mapping makes connecting (yellow),
/// reconnecting (orange), and unreachable/failed (red) distinguishable. All pure / `@MainActor` — no
/// socket, no `HostServer`.
@MainActor
final class PaneStatusIndicatorTests: XCTestCase {

    // MARK: - PaneConnectionStatus.from(_:) mapping

    func testFromMappingColorsAndPulse() {
        // .connecting → yellow, pulsing
        let connecting = PaneConnectionStatus.from(.connecting)
        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertTrue(connecting.pulses)
        XCTAssertEqual(connecting.label, "Connecting…")

        // .connected → green, steady
        let connected = PaneConnectionStatus.from(.connected)
        XCTAssertEqual(connected.phase, .connected)
        XCTAssertFalse(connected.pulses)

        // .reconnecting(n, date) → orange, pulsing, attempt-aware label
        let date = Date().addingTimeInterval(2)
        let reconnecting = PaneConnectionStatus.from(.reconnecting(attempt: 2, nextRetry: date))
        XCTAssertEqual(reconnecting.phase, .reconnecting)
        XCTAssertTrue(reconnecting.pulses)
        XCTAssertEqual(reconnecting.attempt, 2)
        XCTAssertEqual(reconnecting.nextRetry, date)
        XCTAssertEqual(reconnecting.label, "Reconnecting (2)…")

        // .unreachable → red, steady, terminal
        let unreachable = PaneConnectionStatus.from(.unreachable)
        XCTAssertEqual(unreachable.phase, .unreachable)
        XCTAssertFalse(unreachable.pulses)
        XCTAssertEqual(unreachable.label, "Unreachable")

        // .failed → red, with the message carried only in the detailed tooltip
        let failed = PaneConnectionStatus.from(.failed("timed out"))
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.detailedLabel, "Failed: timed out")

        // .disconnected → idle (gray); nil (video / faked handle) → none (no dot)
        XCTAssertEqual(PaneConnectionStatus.from(.disconnected).phase, .idle)
        let none = PaneConnectionStatus.from(nil)
        XCTAssertEqual(none.phase, .none)
        XCTAssertFalse(none.showsDot)
    }

    #if canImport(SwiftUI)
    /// The deliberate colour split that makes connecting / reconnecting / terminal distinguishable.
    func testFromMappingColorSplit() {
        XCTAssertEqual(PaneConnectionStatus.from(.connecting).color, .yellow)
        XCTAssertEqual(PaneConnectionStatus.from(.connected).color, .green)
        XCTAssertEqual(PaneConnectionStatus.from(.reconnecting(attempt: 1, nextRetry: nil)).color, .orange)
        XCTAssertEqual(PaneConnectionStatus.from(.unreachable).color, .red)
        XCTAssertEqual(PaneConnectionStatus.from(.failed("x")).color, .red)
    }
    #endif

    // MARK: - OSC 133 running activity is ORTHOGONAL to the connection status (WF11)

    /// The running flag lives on ``PaneStatusDot``, NOT on ``PaneConnectionStatus`` — so a pane's
    /// connection colour/label/pulse is computed the SAME whether or not a command is running. This
    /// pins the deliberate split: connection state and shell activity never collapse into one enum.
    func testRunningFlagDoesNotAlterConnectionStatusDerivation() {
        // PaneConnectionStatus has no notion of "running"; the same status yields the same dot.
        let connected = PaneConnectionStatus.from(.connected)
        XCTAssertEqual(connected.phase, .connected)
        XCTAssertFalse(connected.pulses, "connected is steady regardless of shell activity")
        #if canImport(SwiftUI)
        XCTAssertEqual(connected.color, .green, "a running command never changes the connection colour")
        #endif
    }

    #if canImport(SwiftUI)
    /// `PaneStatusDot` accepts a `running` flag that defaults to `false`, so every existing call site
    /// (which passes only `status`) is unchanged — the new affordance is purely additive.
    func testPaneStatusDotRunningDefaultsFalse() {
        let dotDefault = PaneStatusDot(status: .from(.connected))
        XCTAssertFalse(dotDefault.running)
        let dotRunning = PaneStatusDot(status: .from(.connected), running: true)
        XCTAssertTrue(dotRunning.running)
    }
    #endif

    /// `ConnectionViewModel.shellActivity` is a read-through to the terminal model — the chrome /
    /// sidebar / palette read the running state from here without touching the terminal model directly.
    func testConnectionViewModelShellActivityReadsThroughToTerminal() {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal, target: { ConnectionTarget(host: "127.0.0.1", port: 7777) },
            makeClient: { fatalError("not invoked") }
        )
        XCTAssertEqual(vm.shellActivity, .idle)
        terminal.handle(.commandStatus(.running))
        XCTAssertEqual(vm.shellActivity, .running, "the view-model reflects the terminal's OSC 133 activity")
        terminal.handle(.commandStatus(.idle(exitCode: 0, durationMS: 11_000)))
        XCTAssertEqual(vm.shellActivity, .idle)
    }

    // MARK: - Tab-level salience fold

    func testFoldPicksMostSalientPhase() {
        // A single reconnecting pane surfaces at the tab level even when a sibling is connected.
        XCTAssertEqual(
            PaneConnectionStatus.fold([.connected, .reconnecting(attempt: 2, nextRetry: nil)]).phase,
            .reconnecting
        )
        // Unreachable beats reconnecting beats connected.
        XCTAssertEqual(
            PaneConnectionStatus.fold([.connected, .reconnecting(attempt: 1, nextRetry: nil), .unreachable]).phase,
            .unreachable
        )
        // All connected → connected.
        XCTAssertEqual(PaneConnectionStatus.fold([.connected, .connected]).phase, .connected)
        // No connections (all video / faked) → none (no rail dot).
        XCTAssertEqual(PaneConnectionStatus.fold([nil, nil]).phase, .none)
        // Empty → none.
        XCTAssertEqual(PaneConnectionStatus.fold([]).phase, .none)
        // A reconnecting fold carries the reconnecting leaf's attempt through to the rail dot.
        XCTAssertEqual(
            PaneConnectionStatus.fold([.connected, .reconnecting(attempt: 3, nextRetry: nil)]).attempt,
            3
        )
    }

    // MARK: - ConnectionViewModel reconnect-progress → status (surfacing WF3)

    /// Builds a `ConnectionViewModel` WITHOUT ever connecting (the `makeClient` closure is stored, never
    /// invoked here — we drive the reconnect-progress folds directly). This keeps the transition test
    /// pure: no socket, no `HostServer`.
    private func makeViewModel() -> ConnectionViewModel {
        ConnectionViewModel(
            terminal: TerminalViewModel(), target: { ConnectionTarget(host: "127.0.0.1", port: 7777) },
            makeClient: { fatalError("makeClient must not be invoked in a pure status-transition test") }
        )
    }

    /// From a dropped/reconnecting state, the supervisor's progress callbacks drive an attempt-aware
    /// `.reconnecting` and the give-up callback flips to the terminal `.unreachable` — the WF3 work made
    /// visible (instead of a frozen "reconnecting" dot).
    func testReconnectProgressThenGiveUpWalksToUnreachable() {
        let vm = makeViewModel()

        // Simulate the drop the events loop produces on a transport FIN.
        vm.applyReconnectProgress(attempt: 0, nextRetry: nil)   // a bare drop is reconnecting(0)
        guard case .reconnecting(let a0, _) = vm.status else { return XCTFail("expected reconnecting") }
        XCTAssertEqual(a0, 0)

        // The supervisor reports a backoff attempt with a next-retry instant.
        let retryAt = Date().addingTimeInterval(0.5)
        vm.applyReconnectProgress(attempt: 2, nextRetry: retryAt)
        guard case .reconnecting(let a2, let next) = vm.status else { return XCTFail("expected reconnecting(2)") }
        XCTAssertEqual(a2, 2)
        XCTAssertEqual(next, retryAt)

        // Campaign exhausted → terminal unreachable.
        vm.applyReconnectGaveUp()
        XCTAssertEqual(vm.status, .unreachable)
    }

    /// Progress / give-up must NOT regress a pane that already recovered to `.connected` (the success
    /// `onProgress` for the winning attempt can race the `.reconnected` event that set `.connected`).
    func testReconnectProgressDoesNotRegressConnected() {
        let vm = makeViewModel()
        vm.applyReconnectProgress(attempt: 1, nextRetry: nil)
        XCTAssertEqual(vm.status.label, "reconnecting (1)")

        // Force a connected state (as the .reconnected event would), then a late progress/give-up.
        vm.forceStatusConnectedForTesting()
        vm.applyReconnectProgress(attempt: 2, nextRetry: Date())
        XCTAssertEqual(vm.status, .connected, "a late progress must not drag a recovered pane back")
        vm.applyReconnectGaveUp()
        XCTAssertEqual(vm.status, .connected, "a late give-up must not whitewash a recovered pane")
    }

    /// R11: a deliberate `disconnect()` lands `.disconnected` and cancels the supervisor — but a
    /// reconnect callback whose hop-`Task` already fired can still run AFTER that. Because
    /// `.disconnected` is BOTH the transient-drop state AND the deliberate-close terminal state, the
    /// late callback would otherwise revive the closed pane to a never-resolving `.reconnecting`
    /// (orange) / `.unreachable` (red). The `deliberatelyClosed` guard must swallow both.
    func testReconnectCallbacksDoNotReviveADeliberatelyClosedPane() async {
        let vm = makeViewModel()
        await vm.disconnect()
        XCTAssertEqual(vm.status, .disconnected)

        vm.applyReconnectProgress(attempt: 1, nextRetry: Date())
        XCTAssertEqual(vm.status, .disconnected, "a late progress must not revive a deliberately-closed pane to reconnecting")

        vm.applyReconnectGaveUp()
        XCTAssertEqual(vm.status, .disconnected, "a late give-up must not flip a deliberately-closed pane to unreachable")
    }

    // MARK: - Failure-reason humanization

    /// The `.failed` reason humanizes a transport `LocalizedError` but PRESERVES the readable Swift
    /// payload for any other error — guarding the regression where `error.localizedDescription` on a
    /// plain `Error` enum (e.g. `ClientError`, thrown by `client.resume()` before connect) bridges to
    /// Foundation's "The operation couldn't be completed. (… error N.)" dump.
    func testFailureReasonHumanizesTransportButPreservesOtherPayloads() {
        XCTAssertEqual(
            ConnectionViewModel.failureReason(for: AislopdeskTransportError.timedOut("connect exceeded 10s")),
            "Connection timed out — host unreachable?",
            "a transport LocalizedError yields its clean errorDescription"
        )
        let clientReason = ConnectionViewModel.failureReason(for: ClientError.invalidState("resume before first connect"))
        XCTAssertEqual(clientReason, #"invalidState("resume before first connect")"#,
                       "a non-LocalizedError keeps its readable Swift payload")
        XCTAssertFalse(clientReason.contains("couldn't be completed"), "must not be the bridged NSError dump")
        XCTAssertFalse(
            ConnectionViewModel.failureReason(for: CancellationError()).contains("couldn't be completed"),
            "CancellationError must not surface as the Foundation dump either"
        )
    }

    /// The status dot overlays a NON-COLOUR "!" glyph for error phases only (WCAG 1.4.1 — red must not
    /// be the sole error cue). Healthy/in-flight/idle phases never show it.
    #if canImport(SwiftUI)
    func testStatusDotShowsNonColorErrorGlyphForErrorPhasesOnly() {
        XCTAssertTrue(PaneStatusDot(status: .from(.failed("boom"))).showsErrorGlyph)
        XCTAssertTrue(PaneStatusDot(status: .from(.unreachable)).showsErrorGlyph)
        XCTAssertFalse(PaneStatusDot(status: .from(.connected)).showsErrorGlyph)
        XCTAssertFalse(PaneStatusDot(status: .from(.connecting)).showsErrorGlyph)
        XCTAssertFalse(PaneStatusDot(status: .from(.reconnecting(attempt: 1, nextRetry: nil))).showsErrorGlyph)
        XCTAssertFalse(PaneStatusDot(status: .from(.disconnected)).showsErrorGlyph)
    }
    #endif

    /// The in-pane recovery banner shows ONLY for the recoverable terminal states (`.failed` carries the
    /// humanized reason; `.unreachable` has a fixed reason). `.reconnecting` is auto-healing (live
    /// countdown in the chrome) and must NOT raise a Retry banner; connecting/connected/disconnected
    /// have no banner. (Drives `PaneLeafView`'s `.failed`/`.unreachable` overlay.)
    #if canImport(SwiftUI)
    func testRecoveryReasonOnlyForFailedAndUnreachable() {
        XCTAssertEqual(
            PaneRecoveryBanner.reason(for: .failed("Connection timed out — host unreachable?")),
            "Connection timed out — host unreachable?",
            ".failed surfaces its humanized message as the banner reason"
        )
        XCTAssertNotNil(PaneRecoveryBanner.reason(for: .unreachable), ".unreachable has a recovery banner")
        XCTAssertNil(PaneRecoveryBanner.reason(for: .disconnected))
        XCTAssertNil(PaneRecoveryBanner.reason(for: .connecting))
        XCTAssertNil(PaneRecoveryBanner.reason(for: .connected))
        XCTAssertNil(
            PaneRecoveryBanner.reason(for: .reconnecting(attempt: 2, nextRetry: nil)),
            "reconnecting is auto-healing → no Retry banner (would duplicate the chrome countdown)"
        )
    }

    /// UI/UX pass-3 #1: a cleanly-exited shell (`.disconnected`) gets a NEUTRAL "session ended" notice —
    /// DISTINCT from the orange error `reason(for:)` (which stays nil for `.disconnected`), so a clean
    /// exit never reads as a failure. Every non-disconnected status has no session-ended notice.
    func testSessionEndedReasonOnlyForDisconnected() {
        XCTAssertNotNil(PaneRecoveryBanner.sessionEndedReason(for: .disconnected),
                        "a clean shell exit gets a neutral session-ended notice")
        XCTAssertNil(PaneRecoveryBanner.reason(for: .disconnected),
                     "…and the orange error banner stays absent (the two affordances are distinct)")
        XCTAssertNil(PaneRecoveryBanner.sessionEndedReason(for: .connected))
        XCTAssertNil(PaneRecoveryBanner.sessionEndedReason(for: .connecting))
        XCTAssertNil(PaneRecoveryBanner.sessionEndedReason(for: .reconnecting(attempt: 1, nextRetry: nil)))
        XCTAssertNil(PaneRecoveryBanner.sessionEndedReason(for: .failed("x")))
        XCTAssertNil(PaneRecoveryBanner.sessionEndedReason(for: .unreachable))
    }
    #endif

    /// The WF3 backoff schedule the published `nextRetry` is derived from is the pure, clock-free
    /// `Backoff.delay(forAttempt:)` — assert it is the capped-exponential sequence the UI countdown
    /// reflects (250ms · 2^(n-1), capped at 2s).
    func testBackoffDelayScheduleIsCappedExponential() {
        let backoff = ReconnectManager.Backoff()   // initial 250ms, max 2s, ×2
        XCTAssertEqual(backoff.delay(forAttempt: 1), .milliseconds(250))
        XCTAssertEqual(backoff.delay(forAttempt: 2), .milliseconds(500))
        XCTAssertEqual(backoff.delay(forAttempt: 3), .seconds(1))
        XCTAssertEqual(backoff.delay(forAttempt: 4), .seconds(2))
        XCTAssertEqual(backoff.delay(forAttempt: 10), .seconds(2), "saturates at the cap")
    }
}
