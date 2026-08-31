import Foundation
import SlopDeskClaudeCode

/// The external input affordance's view-model — a thin `@MainActor @Observable` shell around
/// ``SlopDeskClaudeCode/InputBoxModel`` (which owns ALL the logic: the A/B1 affordance derived
/// from the terminal mode, and the B1 echo-dedup ring).
///
/// Doc 14 (A + B1):
/// - **A — shell command box** (`.shellCommand`): the box sends a whole line on Enter; echo
///   shows normally in the surface above (the ring is bypassed/reset).
/// - **B1 — TUI compose box** (`.tuiCompose`): a fullscreen TUI (Claude Code) owns the screen;
///   the box writes bytes to the PTY on submit (DelayedEnter) and the ring suppresses the
///   PTY's echo of those bytes.
///
/// This shell adds only: `@Observable` mirrors of the model state (`affordance`,
/// `commandRunning`, `lastExitCode`), the bound `compose` text field, and the wiring to
/// `SlopDeskClient.sendInput` (recording sent bytes into the dedup ring in B1). The byte-level
/// dedup + mode tracking stay in `SlopDeskClaudeCode` — this never re-implements them.
@preconcurrency
@MainActor
@Observable
public final class InputBarModel {
    /// The underlying logic model (not `@Observable` itself; we mirror its state here).
    private let box: InputBoxModel

    /// The current affordance, mirrored so a tracked arm can register on it (``box`` is not `@Observable`).
    public private(set) var affordance: InputAffordance
    /// Whether a shell command appears to be running (A-mode block model).
    public private(set) var commandRunning: Bool = false
    /// Exit code of the most recently finished shell command, if any.
    public private(set) var lastExitCode: Int?

    /// The single OUT sink: every send funnels SYNCHRONOUSLY through here, on the main
    /// actor, in true call order — wired by the pane session to
    /// `TerminalViewModel.sendInput` so input-bar bytes ride the SAME per-pane ordered OUT
    /// FIFO as renderer keystrokes (ONE drain per pane). A second OUT path — e.g. the iOS
    /// Coordinator running its own drain, or a per-submit `Task { await client.sendInput }`
    /// on macOS — would race the reentrant client actor and reorder bytes; that's the repo's
    /// recurring unstructured-Task reorder class (docs/29), so all sends must share this one
    /// FIFO. `nil` while the pane is disconnected — sends drop, the designed disconnected
    /// semantic. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var sendSink: ((Data) -> Void)?

    public init(box: InputBoxModel = InputBoxModel()) {
        self.box = box
        affordance = box.affordance
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

    /// ⚠️ THE COMPOSE FIELD AND ITS SUBMIT ARE GONE, and what replaced them is
    /// ``TerminalViewModel/commandPrompt``. This model used to hold the line as a plain `String` for
    /// a `TextField` to bind — a one-line editor with no undo, no selection, no completion and a
    /// cursor counted in Swift `Character`s — and `docs/68` §5.4's whole point is that the line
    /// deserves a real editor. Keeping both would have been two line editors with one PTY behind
    /// them, which is the one-implementation rule failing exactly where it costs most: they only
    /// disagree under a composition or a paste. Deleted at the mount, 2026-09-01.
    ///
    /// What stayed is everything that was never about the text: the affordance, the B1 echo-dedup
    /// ring, and the two raw sends below — which the autotype seam, `cd -`, and synchronized input
    /// all still ride.

    /// Sends a raw byte sequence through ``sendSink``.
    ///
    /// `record` controls whether the bytes enter the B1 echo-dedup ring. The ring exists to
    /// suppress the PTY's **echo** of input the user typed — so it must only ever hold bytes the
    /// PTY will actually echo back (printable / committed-IME text). Control sequences (arrows,
    /// Esc, Tab, Ctrl/Alt codes, floating-cursor `ESC[C`/`ESC[D`) are **not** echoed by the PTY;
    /// recording them would leave them stuck in `pending`, where they could later spuriously match
    /// and swallow a legitimate TUI redraw (e.g. a real `CUF` `ESC[C`). So control sends pass
    /// `record: false`; only ``sendText(_:)`` records.
    public func sendRaw(_ bytes: [UInt8], record: Bool = false) {
        let data = Data(bytes)
        if record, affordance == .tuiCompose {
            box.recordComposeSent(data)
        }
        sendSink?(data)
    }

    /// Sends committed IME / printable `text` (post-composition) as its UTF-8 bytes,
    /// recording it for dedup in B1. Unlike ``submit()`` this appends **no** Enter: the iOS
    /// host streams text as it is composed — as raw bytes, bypassing the engine's key encoder
    /// entirely — and routes Return separately, through `slopdesk_term_surface_key` on the real
    /// surface.
    public func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        sendRaw(Array(text.utf8), record: true)
    }
}
