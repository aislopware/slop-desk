import CSlopDeskFFI
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel

// MARK: - PeekContent (the headless peek DTO + its pure recent-lines builder)

/// The cheap, headless display payload the P4 "Peek & Reply" overlay shows for the target pane (P4 piece
/// 2): its display name, its blocking question (the host type-27 label, or `nil`), and a few "recent
/// output" lines. A PURE value type (no view framework, no store) so the overlay's text is unit-testable without the
/// renderer — the recent lines come from the per-pane block mirror, NOT `TerminalSurface`/`scrollbackLines()`,
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

    /// The recent-output lines for a pane's index-ordered ``CommandBlock`` list (oldest first).
    ///
    /// The fold is `slopdesk_workspace::peek_reply::recent_lines` — which window is kept, what a line
    /// says, and what a still-forming block with no command text prints instead. This is the crossing:
    /// the two fields become two PARALLEL flat blobs under one count, and the lines come back the same
    /// way. Generic over ``PeekBlockLine`` so the caller can hand over any block shape without this file
    /// importing `SlopDeskTerminal`.
    ///
    /// The status labels are asked for as a LIST, through ``PeekBlockLine/statusLabels(of:)``. Read
    /// one at a time they were a door crossing per block — and this runs inside the peek overlay's
    /// `body`, so it is once per block per render pass, to build strings that are flattened straight
    /// back across the same boundary on the next line.
    public static func recentLines<Line: PeekBlockLine>(from blocks: [Line], limit: Int) -> [String] {
        let (commandBlob, commandLengths) = TerminalLinkDetector.flatten(blocks.map(\.commandText))
        let (statusBlob, statusLengths) = TerminalLinkDetector.flatten(Line.statusLabels(of: blocks))
        // A negative limit is clamped rather than rejected: the door's `limit` is a `size_t`, and a
        // negative `Int` reinterpreted there would be an enormous window instead of an empty one.
        // Zero is a real answer the rule already gives, so nothing here decides anything.
        let window = max(0, limit)
        let call = { (out: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
            commandBlob.withUnsafeBufferPointer { commands in
                commandLengths.withUnsafeBufferPointer { commandSizes in
                    statusBlob.withUnsafeBufferPointer { statuses in
                        statusLengths.withUnsafeBufferPointer { statusSizes in
                            slopdesk_ws_peek_recent_lines(
                                commands.baseAddress, commands.count, commandSizes.baseAddress,
                                statuses.baseAddress, statuses.count, statusSizes.baseAddress,
                                blocks.count, window,
                                out.baseAddress, out.count,
                            )
                        }
                    }
                }
            }
        }
        // The exact upper bound rather than a guess: at most `window` lines, each a length word plus
        // its two fields plus the four-byte " · " between them.
        let kept = min(window, blocks.count)
        let capacity = lineCountBytes + kept * (lineCountBytes + separatorBytes)
            + commandBlob.count + statusBlob.count
        var out = [UInt8](repeating: 0, count: capacity)
        var needed = out.withUnsafeMutableBufferPointer(call)
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer(call)
        }
        return decodeLines(out, needed)
    }

    /// `[uint32 count]`, and one `[uint32 length]` per line.
    private static let lineCountBytes = 4

    /// The UTF-8 width of `" · "` — the widest a line can grow past its two fields.
    private static let separatorBytes = 4

    /// Reads `[uint32 count]`, that many `[uint32 length]` words, and the runs they name.
    ///
    /// A truncated answer decodes to nothing rather than to a partial tail: the block is a transcript,
    /// and a transcript missing its last line reads as a command that never ran.
    private static func decodeLines(_ bytes: [UInt8], _ length: Int) -> [String] {
        guard length >= lineCountBytes, length <= bytes.count else { return [] }
        let word = { (at: Int) -> Int in
            var value = 0
            for offset in at..<(at + lineCountBytes) { value = value << 8 | Int(bytes[offset]) }
            return value
        }
        let count = word(0)
        var cursor = lineCountBytes + count * lineCountBytes
        guard length >= cursor else { return [] }
        var lines: [String] = []
        lines.reserveCapacity(count)
        for index in 0..<count {
            let run = word(lineCountBytes + index * lineCountBytes)
            guard cursor + run <= length else { return [] }
            // The producer is `slopdesk_workspace::peek_reply`, so these bytes are a Rust `String`'s
            // and cannot be invalid UTF-8. A failable init would add a `nil` branch with no failure
            // mode behind it — and the caller would have to invent a meaning for it.
            lines.append(String(decoding: bytes[cursor..<(cursor + run)], as: UTF8.self))
            cursor += run
        }
        return lines
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
    /// Every line's ``statusLabel``, in order — the form a caller holding the whole list asks for.
    ///
    /// A REQUIREMENT rather than only an extension, so the witness table dispatches to a conformer
    /// that can answer the list in one go: `CommandBlock`'s label is derived through the block-status
    /// door, and asking it per member is a crossing per block per render of the peek overlay. The
    /// default below is the honest loop, which is what a stand-in whose label is just a stored
    /// string wants.
    static func statusLabels(of lines: [Self]) -> [String]
}

public extension PeekBlockLine {
    /// One at a time, for a conformer whose label costs nothing to read.
    static func statusLabels(of lines: [Self]) -> [String] { lines.map(\.statusLabel) }
}

// MARK: - PeekReplyTarget (the pure "which blocked pane does ⌘⌥J answer" selection)

/// The face over `slopdesk-agent`'s `attention::peek_target` / `peek_queue` — given the FOCUSED pane, a
/// status lookup and the canonical-order pane list, which pane's blocked agent the human should answer
/// INLINE, and where that pane sits in the triage queue.
///
/// Distinct from ``AttentionJump`` (⌘⇧U "jump TO the pane") by exactly one clause, which is why the two
/// live in the SAME Rust module: jump MOVES focus, so it has no reason to prefer where you already are;
/// peek-reply REPLIES in place, so a focused pane that is itself blocked is answered first. Written
/// apart, that clause is the seam a second ordering grows out of.
///
/// The pane identities never leave Swift. What crosses is a run of status bytes, a run of
/// already-answered flags, and the focused pane's own two facts — and what comes back is a POSITION in
/// the list this side handed over, or a flag naming the focused pane, which need not be in that list.
public enum PeekReplyTarget {
    /// The pane ⌘⌥J should peek + reply to, or `nil` when nothing needs attention (a no-op / read-only
    /// peek of `focused` is the caller's choice).
    ///
    /// `excluding` (default empty) is the advance-to-next exclusion: right after a reply the just-answered
    /// pane may still report `.needsPermission` until the host re-reports, so the immediate advance drops
    /// it from BOTH the focused-first clause and the candidate set — else ⌘⌥J would re-target the same pane.
    public static func select(
        focused: PaneID?,
        status: (PaneID) -> ClaudeStatus,
        panes: some Sequence<PaneID>,
        excluding: Set<PaneID> = [],
    ) -> PaneID? {
        let ordered = Array(panes)
        let statuses = ordered.map { status($0).ffiByte }
        let answered = ordered.map { excluding.contains($0) }
        let target = statuses.withUnsafeBufferPointer { statusBytes in
            answered.withUnsafeBufferPointer { answeredFlags in
                slopdesk_agent_peek_target(
                    focused != nil,
                    focused.map { status($0).ffiByte } ?? 0,
                    focused.map { excluding.contains($0) } ?? false,
                    statusBytes.baseAddress, answeredFlags.baseAddress, ordered.count,
                )
            }
        }
        guard target.present else { return nil }
        if target.is_focused { return focused }
        guard target.position < ordered.count else { return nil }
        return ordered[target.position]
    }

    /// The "N of M" triage-queue position for the header counter, or `nil` when the total is under 2 —
    /// a queue of one is not a queue, and the calm static "Peek & Reply" caption stays instead.
    ///
    /// `excluding`'s COUNT crosses beside its flags, because the two answer different questions: the flags
    /// say which of these panes are already done with, and the count says how many this run has answered
    /// at all — including panes that have since closed and left the list.
    public static func queuePosition(
        status: (PaneID) -> ClaudeStatus,
        panes: some Sequence<PaneID>,
        excluding: Set<PaneID>,
    ) -> (position: Int, total: Int)? {
        let ordered = Array(panes)
        let statuses = ordered.map { status($0).ffiByte }
        let answered = ordered.map { excluding.contains($0) }
        let queue = statuses.withUnsafeBufferPointer { statusBytes in
            answered.withUnsafeBufferPointer { answeredFlags in
                slopdesk_agent_peek_queue(
                    statusBytes.baseAddress, answeredFlags.baseAddress, ordered.count, excluding.count,
                )
            }
        }
        guard queue.present else { return nil }
        return (position: Int(queue.position), total: Int(queue.total))
    }
}

// MARK: - PeekReplyFormatter (the pure "what bytes does this reply send" formatting)

/// The face over `slopdesk-workspace`'s `peek_reply` — what the human typed, as the exact text the
/// pane's PTY should receive.
///
/// Every reply ends in a single trailing newline (the agent / shell reads a line), and the rule about
/// which shape a field is — a `!`-prefixed shell line, a quick-answer digit, or plain text — is Rust's.
/// `nil` here is the door's `0`: nothing to send, and the caller no-ops.
public enum PeekReplyFormatter {
    /// The text to send for a free-text reply `field`, or `nil` when there is nothing to send.
    public static func reply(for field: String) -> String? {
        let answer = wsTransform(field) { bytes, len, out, cap in
            slopdesk_ws_peek_reply_text(bytes, len, out, cap)
        }
        // Rust's, therefore valid UTF-8 — see the note in `decodeLines`.
        return answer.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The text to send for a quick-answer digit `n`, or `nil` for a key that is not one. A separate
    /// entry point (NOT routed through ``reply(for:)``) because it fires on a key press while the field
    /// is empty, not on submit.
    public static func quickAnswer(_ n: Int) -> String? {
        // "<n>\n" is two bytes; the door reports its own size, so this is only the inline guess.
        wsDelivered(capacity: 8) { out, cap in
            slopdesk_ws_peek_quick_answer(Int32(clamping: n), out, cap)
        }
    }
}
