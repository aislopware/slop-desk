import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 (WI-5 cluster): `TerminalViewModel.isAlternateScreen` — the REAL alt-screen flag the E8 paste /
/// backspace / scroll-past GUI gates read instead of the coarse `shellActivity == .running` proxy.
///
/// The flag is derived from the client `TerminalModeTracker` (DECSET 1049/47/1047) fed in `ingestPass`.
/// The load-bearing fix is that the tracker is fed UNCONDITIONALLY — the old code only fed it while the
/// glitch caret was enabled (`glitchCaretMode != .off`), which is NOT the default, so the accessor would
/// have been stuck on `shellPrompt`. These tests pin the accessor with the glitch caret explicitly OFF, so
/// reverting the "feed unconditionally" change (moving `modeTracker.consume` back inside the glitch-caret
/// gate) makes `testAltScreenTrackedWithGlitchCaretOff` fail (the flag never flips).
@MainActor
final class TerminalAlternateScreenTests: XCTestCase {
    private let enterAlt = Data("\u{1B}[?1049h".utf8)
    private let exitAlt = Data("\u{1B}[?1049l".utf8)

    private func makeConnectedModel(
        glitchCaret: TerminalViewModel.GlitchCaretMode = .off,
    ) -> TerminalViewModel {
        let model = TerminalViewModel()
        model.glitchCaretMode = glitchCaret
        model.handle(.reconnected(sessionID: UUID(), resumeFromSeq: 0)) // → .connected
        return model
    }

    /// Fresh model is on the primary (shell) screen.
    func testStartsOnPrimaryScreen() {
        let model = makeConnectedModel()
        XCTAssertFalse(model.isAlternateScreen)
    }

    /// With the glitch caret OFF (the default), a `?1049h` ingest STILL flips the flag, and `?1049l` clears
    /// it — proving the mode tracker is fed regardless of the glitch-caret feature (the revert-to-fail pin).
    func testAltScreenTrackedWithGlitchCaretOff() {
        let model = makeConnectedModel(glitchCaret: .off)

        model.ingestOutput(enterAlt)
        XCTAssertTrue(
            model.isAlternateScreen,
            "entering a full-screen TUI must flip isAlternateScreen even with the glitch caret off",
        )

        model.ingestOutput(exitAlt)
        XCTAssertFalse(model.isAlternateScreen, "leaving the TUI must clear isAlternateScreen")
    }

    /// A split escape sequence across two ingest chunks is still tracked (the byte-at-a-time machine holds
    /// partial state between passes) — a TUI's enter sequence must not be missed on a TCP boundary.
    func testAltScreenTrackedAcrossChunkBoundary() {
        let model = makeConnectedModel(glitchCaret: .off)
        let bytes = Array("\u{1B}[?1049h".utf8)
        let split = bytes.count / 2
        model.ingestOutput(Data(bytes[..<split]))
        XCTAssertFalse(model.isAlternateScreen, "must not classify a partial sequence as alt-screen")
        model.ingestOutput(Data(bytes[split...]))
        XCTAssertTrue(model.isAlternateScreen, "the completed sequence flips the flag")
    }
}
