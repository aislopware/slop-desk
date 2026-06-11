import Foundation
import AislopdeskClaudeCode
import AislopdeskClient

/// The external input affordance's view-model — a thin `@MainActor @Observable` shell around
/// ``AislopdeskClaudeCode/InputBoxModel`` (which owns ALL the logic: the A/B1 affordance derived
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
/// `AislopdeskClient.sendInput` (recording sent bytes into the dedup ring in B1). The byte-level
/// dedup + mode tracking stay in `AislopdeskClaudeCode` — this never re-implements them.
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
    public func submit(over client: AislopdeskClient) async {
        guard let bytes = encodeSubmit() else { return }
        compose = ""
        try? await client.sendInput(bytes)
    }

    /// Sends a raw byte sequence over `client`.
    ///
    /// `record` controls whether the bytes enter the B1 echo-dedup ring. The ring exists to
    /// suppress the PTY's **echo** of input the user typed — so it must only ever hold bytes the
    /// PTY will actually echo back (printable / committed-IME text). Control sequences (arrows,
    /// Esc, Tab, Ctrl/Alt codes, floating-cursor `ESC[C`/`ESC[D`) are **not** echoed by the PTY;
    /// recording them would leave them stuck in `pending`, where they could later spuriously match
    /// and swallow a legitimate TUI redraw (e.g. a real `CUF` `ESC[C`). So control sends pass
    /// `record: false`; only ``sendText(_:over:)`` records.
    public func sendRaw(_ bytes: [UInt8], over client: AislopdeskClient, record: Bool = false) async {
        let data = Data(bytes)
        if record, affordance == .tuiCompose {
            box.recordComposeSent(data)
        }
        try? await client.sendInput(data)
    }

    /// Sends committed IME / printable `text` (post-composition) over `client` as its UTF-8
    /// bytes, recording it for dedup in B1. Unlike ``submit(over:)`` this appends **no** Enter:
    /// the iOS host streams text as it is composed and routes Return as a separate key, matching
    /// `ghostty_surface_text` (text) vs `ghostty_surface_key` (Enter) on the real surface.
    public func sendText(_ text: String, over client: AislopdeskClient) async {
        guard !text.isEmpty else { return }
        await sendRaw(Array(text.utf8), over: client, record: true)
    }
}
