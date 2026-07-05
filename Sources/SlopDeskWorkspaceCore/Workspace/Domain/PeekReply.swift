import Foundation
import SlopDeskAgentDetect

// MARK: - PeekContent (the headless peek DTO + its pure recent-lines builder)

/// The cheap, headless display payload the P4 "Peek & Reply" overlay shows for the target pane (P4 piece
/// 2): its display name, its blocking question (the host type-27 label, or `nil`), and a few "recent
/// output" lines. A PURE value type (no SwiftUI / store) so the overlay's text is unit-testable without the
/// renderer — the recent lines come from the per-pane block mirror, NOT `GhosttySurface`/`scrollbackText…`,
/// so it compiles + tests under headless `swift build`.
public struct PeekContent: Equatable, Sendable {
    /// The pane's display name (its spec title).
    public let title: String
    /// The blocking question / prompt the agent is waiting on (the host type-27 ``WorkspaceStore``
    /// `paneAgentLabel`), or `nil` when none was reported.
    public let question: String?
    /// The last few command-block lines (oldest-first), the "recent output" stand-in. Empty when the pane
    /// has no terminal model / no blocks — the view then shows a "no recent output" note.
    public let recent: [String]

    public init(title: String, question: String?, recent: [String]) {
        self.title = title
        self.question = question
        self.recent = recent
    }

    /// Pure builder for the recent-output lines from a pane's index-ordered ``CommandBlock`` list (oldest
    /// first): takes the newest `limit` blocks and renders one line each as `"<command> · <status>"` (the
    /// command text trimmed, with its status label — "running…" / "exit 0" / "exit 137"). Blocks with an
    /// empty command line render their status alone. The result is oldest-first within the kept window so it
    /// reads top-to-bottom like a transcript tail. Generic over a tiny line-shape protocol so it is testable
    /// with a stand-in (no `SlopDeskTerminal` import in the test).
    public static func recentLines(from blocks: [some PeekBlockLine], limit: Int) -> [String] {
        guard limit > 0, !blocks.isEmpty else { return [] }
        let kept = blocks.suffix(limit)
        return kept.map { block in
            let cmd = block.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? block.statusLabel : "\(cmd) · \(block.statusLabel)"
        }
    }
}

/// The tiny shape ``PeekContent/recentLines(from:limit:)`` reads off a command block — its typed command
/// line and a short status label. `CommandBlock` (in `SlopDeskTerminal`) conforms via an extension, so the
/// builder stays pure (no `SlopDeskTerminal` import here) and a test can feed a stand-in struct.
public protocol PeekBlockLine {
    /// The typed command line (no prompt), as the host segmented it. Empty for a still-forming block.
    var commandText: String { get }
    /// A short, human status label ("running…", "exit 0", "exit 137").
    var statusLabel: String { get }
}

// MARK: - PeekReplyTarget (the pure "which blocked pane does ⌘⇧J answer" selection)

/// The PURE selection policy for the P4 "Peek & Reply" overlay (⌘⇧J): given the FOCUSED pane, a status
/// lookup, and the canonical-order pane list, pick the pane whose blocked agent the human should answer
/// INLINE — without a full tab/context switch.
///
/// Distinct from ``AttentionJump`` (⌘⇧U "jump TO the pane"): jump MOVES focus to the oldest attention
/// pane; peek-reply REPLIES to it in place and may keep the human where they are. The selection rule
/// therefore has one extra clause: a FOCUSED pane that is itself blocked (`.needsPermission`) is answered
/// first (you are already looking at it), and only then does it fall back to the oldest-attention order.
///
/// Split from the store + the view so the rule (focused-blocked-first, then oldest-attention, with an
/// optional exclusion for advance-to-next) is unit-tested with NO `WorkspaceStore` and NO SwiftUI — the
/// store passes `tree.activeSession?.activeTab?.activePane`, its `agentStatus(for:)` closure, and
/// `tree.allPaneIDs()`. `#if`-unguarded so it compiles + tests on every platform.
public enum PeekReplyTarget {
    /// The pane ⌘⇧J should peek + reply to, or `nil` when nothing needs attention (a no-op / read-only
    /// peek of `focused` is the caller's choice).
    ///
    /// Priority:
    ///  1. `focused` when it is `.needsPermission` (you are already on a blocked pane — answer it first),
    ///     UNLESS it is in `excluding` (the just-answered pane on an immediate advance).
    ///  2. else the oldest attention pane via ``AttentionJump/oldestPane(in:status:)`` — needsPermission
    ///     before done, oldest-first — over `panes` MINUS `excluding`.
    ///  3. else `nil`.
    ///
    /// `excluding` (default empty) is the advance-to-next exclusion: right after a reply the just-answered
    /// pane may still report `.needsPermission` until the host re-reports, so the immediate advance drops
    /// it from BOTH the focused-first clause and the candidate set — else ⌘⇧J would re-target the same pane.
    public static func select(
        focused: PaneID?,
        status: (PaneID) -> ClaudeStatus,
        panes: some Sequence<PaneID>,
        excluding: Set<PaneID> = [],
    ) -> PaneID? {
        // 1. The focused pane, if it is blocked and not the one we just answered.
        if let focused, !excluding.contains(focused), status(focused) == .needsPermission {
            return focused
        }
        // 2. The oldest attention pane over the remaining candidates.
        return AttentionJump.oldestPane(
            in: panes.lazy.filter { !excluding.contains($0) },
            status: status,
        )
    }
}

// MARK: - PeekReplyFormatter (the pure "what bytes does this reply send" formatting)

/// The PURE reply-formatting policy for the P4 overlay: converts what the human typed (a free-text line,
/// a quick-answer digit, or a `!`-prefixed shell line) into the exact text the pane's PTY should receive.
///
/// Every reply ends in a single trailing newline (the agent / shell reads a line). The three shapes:
///  - a quick-answer DIGIT (1–9, fired by a number key when the field is empty) → `"<n>\n"` — the common
///    "pick option N of a numbered multiple-choice prompt" case;
///  - a `!`-prefixed line → the rest, trimmed of the leading `!` (a shell line the human wants run in the
///    same PTY — no privilege change, it is just bytes to the same shell the agent runs in);
///  - any other non-empty line → itself + `"\n"`.
///
/// `nil` for an empty / whitespace-only field (nothing to send — the caller no-ops). `nonisolated` +
/// `#if`-unguarded so it composes from any context and tests on every platform.
public enum PeekReplyFormatter {
    /// The text to send for a free-text reply `field`, or `nil` when there is nothing to send.
    ///
    /// A leading `!` strips to a shell line (`"!ls"` → `"ls\n"`); a `!` with nothing after it is treated
    /// as empty (nothing to send). Otherwise the trimmed line + a single newline. Leading/trailing
    /// whitespace around the WHOLE field is trimmed; interior spacing is preserved.
    public static func reply(for field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("!") {
            let shell = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shell.isEmpty else { return nil }
            return shell + "\n"
        }
        return trimmed + "\n"
    }

    /// The text to send for a quick-answer digit `n` (1–9), as `"<n>\n"`. `nil` for an out-of-range value
    /// so the caller can ignore a stray key. The digit path is a separate entry point (NOT routed through
    /// ``reply(for:)``) because it fires on a key press while the field is empty, not on submit.
    public static func quickAnswer(_ n: Int) -> String? {
        guard (1...9).contains(n) else { return nil }
        return "\(n)\n"
    }
}
