import CSlopDeskFFI
import Foundation

/// Classifies one client→PTY input chunk: does it carry a USER KEYSTROKE, or only the terminal
/// emulator's own automatic traffic — and, more narrowly, does it carry a CANCEL key?
///
/// The same `input` frames that carry keystrokes also carry replies the client terminal emits with
/// no human behind them — focus in/out (`CSI I`/`CSI O`, sent by merely VISITING a pane), cursor
/// position / device-attribute / window-geometry reports answering the program's queries, and mouse
/// events (motion included: the renderer forwards every pointer position to a mouse-reporting TUI, so
/// merely HOVERING a pane floods this path). The unblock signal must fire on none of those: a visit,
/// a scroll or a hover is READING a blocked pane, not answering its dialog.
///
/// Pure + total (validate-then-drop): any byte sequence is tolerated; a sequence truncated at the
/// chunk boundary classifies as NOT a keystroke (conservative — never demote on an unknowable
/// fragment). The one deliberate exception: a chunk ENDING in a bare `ESC` is the Esc key's legacy
/// encoding — the exact key that cancels a dialog — not a truncated report (reports arrive as
/// complete writes).
public enum PaneInputClassifier {
    /// True iff `bytes` contains at least one user keystroke.
    public static func containsUserKeystroke(_ bytes: Data) -> Bool {
        agentScan(bytes) { pointer, count in
            slopdesk_agent_contains_user_keystroke(pointer, count)
        }
    }

    /// True iff `bytes` contains a CANCEL key — `Esc` in ANY of its encodings (the bare legacy
    /// `0x1B`, `ESC ESC`, and kitty's `CSI 27 u`, which is what Claude Code's own keyboard mode
    /// actually sends) or `Ctrl-C` (`0x03`, still legacy under kitty's disambiguate flag).
    ///
    /// This, not ``containsUserKeystroke(_:)``, is what may demote a standing `.needsPermission`
    /// (see the note on `ClaudeSignal.userInput`). The unblock exists for exactly ONE case — an
    /// Esc-cancelled dialog, which fires no hook and would otherwise leave the pane blocked forever
    /// — and every OTHER way of resolving a dialog announces itself: answering a permission prompt
    /// fires `PreToolUse`, answering an `AskUserQuestion` fires its `PostToolUse`. Demoting on ANY
    /// keystroke therefore bought nothing and cost a false edge: arrowing between an
    /// `AskUserQuestion`'s options, or retyping an answer, walked the pane blocked → idle, the
    /// still-visible dialog walked it straight back to blocked, and the second entry rang the
    /// awaiting-input cue again — once per keypress (user-reported 2026-08-10).
    public static func containsCancelKeystroke(_ bytes: Data) -> Bool {
        agentScan(bytes) { pointer, count in
            slopdesk_agent_contains_cancel_keystroke(pointer, count)
        }
    }

    /// The ONE scanner behind both predicates is `rust/slopdesk-agent::input` (docs/55) — the walk
    /// that consumes the emulator's automatic replies, shared so a report shape taught to one
    /// question is known to both. This is only the pointer scope around it.
    private static func agentScan(_ bytes: Data, _ call: (UnsafePointer<UInt8>?, Int) -> Bool) -> Bool {
        bytes.withUnsafeBytes { raw in
            call(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }
}
