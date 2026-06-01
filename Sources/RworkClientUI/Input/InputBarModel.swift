import Foundation
import RworkClaudeCode
import RworkClient

/// The external input affordance's view-model — a thin `@MainActor @Observable` shell around
/// ``RworkClaudeCode/InputBoxModel`` (which owns ALL the logic: the A/B1 affordance derived
/// from the terminal mode, and the B1 echo-dedup ring).
///
/// Doc 14 (A + B1):
/// - **A — shell command box** (`.shellCommand`): the box sends a whole line on Enter; echo
///   shows normally in the surface above (the ring is bypassed/reset).
/// - **B1 — TUI compose box** (`.tuiCompose`): a fullscreen TUI (Claude Code) owns the screen;
///   the box writes bytes to the PTY on submit (DelayedEnter) and the ring suppresses the
///   PTY's echo of those bytes.
///
/// This shell adds only: SwiftUI-observable mirrors of the model state (`affordance`,
/// `commandRunning`, `lastExitCode`), the bound `compose` text field, and the wiring to
/// `RworkClient.sendInput` (recording sent bytes into the dedup ring in B1). The byte-level
/// dedup + mode tracking stay in `RworkClaudeCode` — this never re-implements them.
@MainActor
@Observable
public final class InputBarModel {
    /// The underlying logic model (not `@Observable` itself; we mirror its state here).
    private let box: InputBoxModel

    /// The current affordance, mirrored for SwiftUI tracking.
    public private(set) var affordance: InputAffordance
    /// Whether a shell command appears to be running (A-mode block model).
    public private(set) var commandRunning: Bool = false
    /// Exit code of the most recently finished shell command, if any.
    public private(set) var lastExitCode: Int?

    /// The compose-field text (bound to the `TextField`).
    public var compose: String = ""

    public init(box: InputBoxModel = InputBoxModel()) {
        self.box = box
        self.affordance = box.affordance
    }

    /// Feeds an inbound `output` chunk through the model so the affordance + dedup track the
    /// terminal mode. Returns the bytes to actually render (B1 strips echo; A passes through).
    /// Call this from the `TerminalViewModel` output path when the input bar is in use.
    @discardableResult
    public func ingestOutput(_ output: Data) -> Data {
        let rendered = box.ingestOutput(output)
        affordance = box.affordance
        commandRunning = box.commandRunning
        lastExitCode = box.lastExitCode
        return rendered
    }

    /// Encodes the current compose text into the bytes to write to the PTY, per affordance:
    /// - **A**: the line plus a carriage return (the shell reads a full line on Enter).
    /// - **B1**: the line plus a carriage return as well, but the bytes are recorded into the
    ///   dedup ring so the TUI's echo is suppressed (DelayedEnter handled by the caller's
    ///   send cadence; the byte content is identical).
    ///
    /// Returns `nil` for an empty compose (nothing to send).
    public func encodeSubmit() -> Data? {
        let text = compose
        guard !text.isEmpty else { return nil }
        var bytes = Data(text.utf8)
        bytes.append(0x0D) // CR — Enter
        if affordance == .tuiCompose {
            box.recordComposeSent(bytes)
        }
        return bytes
    }

    /// Submits the compose field over `client` and clears it. In B1 the sent bytes are
    /// already recorded for echo-dedup by ``encodeSubmit()``.
    public func submit(over client: RworkClient) async {
        guard let bytes = encodeSubmit() else { return }
        compose = ""
        try? await client.sendInput(bytes)
    }

    /// Sends a raw byte sequence (e.g. an accessory-bar Ctrl/Esc/Tab/arrow, or a
    /// floating-cursor arrow run) over `client`, recording it for dedup in B1.
    public func sendRaw(_ bytes: [UInt8], over client: RworkClient) async {
        let data = Data(bytes)
        if affordance == .tuiCompose {
            box.recordComposeSent(data)
        }
        try? await client.sendInput(data)
    }
}
