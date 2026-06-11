import Foundation

/// What the external input box should offer the user right now — derived from the
/// terminal mode (doc 14 §"Ô input ngoài", decision **A + B1**). Logic-only; no SwiftUI.
public enum InputAffordance: Sendable, Equatable {
    /// **A — shell command box.** At a shell prompt: the box sends a whole line on Enter
    /// and a block boundary is marked at the prompt (OSC 133). Echo flows normally in the
    /// surface above.
    case shellCommand
    /// **B1 — TUI compose-box.** A fullscreen TUI (Claude Code interactive) owns the
    /// screen: overlay a compose-box, write bytes to the PTY on submit with DelayedEnter,
    /// and dedup the PTY's echo.
    case tuiCompose
}

/// A small state machine tying ``TerminalModeTracker`` (mode) + ``InputDedupRing`` (echo
/// suppression) together and exposing the current input affordance to the UI layer.
///
/// Pure logic, no UI: it feeds output bytes through the tracker, flips affordance when
/// the mode changes, and offers `recordSent` / `filterOutput` helpers that drive the
/// dedup ring **only while in B1 compose mode** (in shell-A mode echo is shown normally,
/// so the ring is bypassed and reset).
public final class InputBoxModel {
    private let tracker: TerminalModeTracker
    private let dedup: InputDedupRing

    /// The current input affordance. `.shellCommand` while at a shell prompt,
    /// `.tuiCompose` while a fullscreen TUI owns the alternate screen.
    public private(set) var affordance: InputAffordance = .shellCommand

    /// Whether a shell command appears to be running (between OSC 133 `C` and `D`). Used
    /// by the A-mode block model; the box may surface a "running" state here.
    public private(set) var commandRunning: Bool = false

    /// The exit code of the most recently finished shell command, if any.
    public private(set) var lastExitCode: Int?

    /// Optional sink the UI can observe for every tracker event (mode + command marks).
    public var onEvent: ((TerminalModeEvent) -> Void)?

    public init(
        tracker: TerminalModeTracker = TerminalModeTracker(),
        dedup: InputDedupRing = InputDedupRing()
    ) {
        self.tracker = tracker
        self.dedup = dedup
        self.affordance = Self.affordance(for: tracker.mode)
    }

    /// The current terminal mode (passthrough for inspection).
    public var mode: TerminalMode { tracker.mode }

    // MARK: Output ingestion

    /// Feeds an output chunk through the tracker, updates affordance + command state, and
    /// returns the bytes to actually render. In **B1 (compose)** mode the dedup ring
    /// strips the echo of compose-box input; in **A (shell)** mode output passes through
    /// untouched (echo is meant to show) and the ring is reset.
    @discardableResult
    public func ingestOutput(_ output: Data) -> Data {
        let events = tracker.consume(output)
        for event in events {
            apply(event)
            onEvent?(event)
        }
        affordance = Self.affordance(for: tracker.mode)

        switch affordance {
        case .tuiCompose:
            return dedup.filter(output)
        case .shellCommand:
            dedup.reset()
            return output
        }
    }

    @discardableResult
    public func ingestOutput(_ output: [UInt8]) -> [UInt8] {
        Array(ingestOutput(Data(output)))
    }

    // MARK: Compose-box send (B1)

    /// Records bytes the compose-box wrote to the PTY so their echo can be suppressed.
    /// Only meaningful in `.tuiCompose`; a no-op record in `.shellCommand` (echo shows).
    public func recordComposeSent(_ bytes: Data) {
        guard affordance == .tuiCompose else { return }
        dedup.recordSent(bytes)
    }

    public func recordComposeSent(_ bytes: [UInt8]) { recordComposeSent(Data(bytes)) }

    // MARK: Event application

    private func apply(_ event: TerminalModeEvent) {
        switch event {
        case .enteredAltScreen, .exitedAltScreen:
            // Mode flip clears any half-matched echo state.
            dedup.reset()
        case .commandStarted:
            commandRunning = true
        case .commandFinished(let code):
            commandRunning = false
            lastExitCode = code
        case .promptStart, .commandStart:
            commandRunning = false
        }
    }

    private static func affordance(for mode: TerminalMode) -> InputAffordance {
        switch mode {
        case .shellPrompt: return .shellCommand
        case .altScreen: return .tuiCompose
        }
    }
}
