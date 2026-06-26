import Foundation

/// One pending prompt in the ``PromptQueueModel`` — a stable identity plus its raw text.
///
/// The `id` is what the UI binds chips to (tap-to-edit, drag-to-reorder, ✕-remove) and
/// what ``PromptQueueModel/take(id:)`` / ``PromptQueueModel/removeItem(id:)`` address, so a
/// reorder can't make a chip act on the wrong item.
public struct PromptQueueItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// PURE, headless prompt queue (otty "Prompt Queue", `⌘⇧M` / Composer `⌥⌘↩`).
///
/// Lines up prompts while an agent is mid-turn and hands the next one out when the pane
/// goes idle. This type is the **contract everything else binds to** (E12 WI-1): it holds
/// the ordered items and the dispatch logic and **nothing else** — no SwiftUI, no
/// `@MainActor`, and **no send side-effects**. ``dispatchNext()`` *returns* the head item's
/// bytes; the caller (``ComposerModel``) is the one that writes them through the pane's
/// single ordered-OUT send sink. That keeps the queue a value type that unit-tests headless
/// and never reaches a socket itself.
///
/// Dispatch is one item per idle, FIFO, both for normal shell panes (OSC-133 `;A` prompt
/// mark) and alt-screen agent panes (`claudeStatus → .idle`); both signals funnel into the
/// same ``dispatchNext()`` at the ``ComposerModel`` layer.
///
/// Mutations validate-then-degrade: out-of-range indices / unknown ids are no-ops, never a
/// trap (an attacker doesn't reach here, but a stale UI index can).
public struct PromptQueueModel: Sendable, Equatable {
    /// The ordered pending prompts. Head is dispatched first.
    public private(set) var items: [PromptQueueItem] = []

    public init() {}

    /// `true` when nothing is queued — drives the queue-strip's "hidden when empty".
    public var isEmpty: Bool { items.isEmpty }

    // MARK: Enqueue

    /// Appends a draft to the queue, splitting it into **one item per non-blank line**
    /// (each trimmed). A single-line draft (the `⌘⇧M` queue-input-bar `↩` path) yields one
    /// item; a multi-line Composer draft (`⌥⌘↩`) yields one per line, blank lines dropped.
    /// Returns the ids of the appended items (the Composer uses this to re-select an item
    /// for editing); discardable.
    @discardableResult
    public mutating func enqueue(_ draft: String) -> [PromptQueueItem.ID] {
        let appended = Self.splitLines(draft).map { PromptQueueItem(text: $0) }
        items.append(contentsOf: appended)
        return appended.map(\.id)
    }

    // MARK: Reorder / remove / edit-pop

    /// Moves the item at `source` so it ends up at index `destination` (drag-to-reorder).
    /// `destination` is the **final** index in the resulting array; both indices are clamped
    /// and an out-of-range / no-op move is dropped silently.
    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), items.count - 1)
        guard source != clamped else { return }
        let item = items.remove(at: source)
        items.insert(item, at: clamped)
    }

    /// Removes the item with `id` without dispatching it (the chip's ✕ button). Unknown id
    /// is a no-op.
    public mutating func removeItem(id: PromptQueueItem.ID) {
        items.removeAll { $0.id == id }
    }

    /// Removes the item with `id` and returns its text — the **edit** path: tapping a chip
    /// pops it back into the Composer for editing. Returns `nil` for an unknown id.
    @discardableResult
    public mutating func take(id: PromptQueueItem.ID) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index).text
    }

    // MARK: Dispatch

    /// Pops the head item and returns the bytes to write to the PTY: **UTF-8(text) + CR**
    /// (`0x0D`), byte-identical to a typed line submitted at the prompt. Returns `nil` when
    /// the queue is empty (the idle signal then has nothing to dispatch). **No send
    /// side-effect** — the caller writes the returned bytes.
    public mutating func dispatchNext() -> Data? {
        guard !items.isEmpty else { return nil }
        let head = items.removeFirst()
        var bytes = Data(head.text.utf8)
        bytes.append(0x0D) // CR — submit, like Enter at the prompt.
        return bytes
    }

    // MARK: Helpers

    /// Splits a draft into trimmed, non-blank lines, in order. Robust to `\n`, `\r`, and
    /// `\r\n` (every newline grapheme is a separator); leading/trailing whitespace per line
    /// is stripped and empty lines are dropped.
    private static func splitLines(_ draft: String) -> [String] {
        draft
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
