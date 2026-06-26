import AislopdeskClaudeCode
import Foundation

/// Per-pane composer view-model (otty "Composer", `⌘⇧E`) — the `@MainActor @Observable`
/// shell that owns the draft, the visibility/pin/float chrome flags, and a
/// ``AislopdeskClaudeCode/PromptQueueModel`` (the `⌘⇧M` Prompt Queue, E12 WI-1).
///
/// It holds **no** transport of its own. Every byte it emits — a `⌘↩` send and each
/// idle-dispatched queue item — funnels through the single injected ``send`` closure, which
/// the durable ``LivePaneSession`` wires to the pane's `InputBarModel.sendText`/`sendRaw`
/// (E12 WI-4). That keeps composer output on the **one** per-pane ordered-OUT FIFO + B1
/// echo-dedup ring — never a second socket, never an unstructured `Task` that could reorder
/// against renderer keystrokes (docs/29). `send` is `nil` while the pane is disconnected; a
/// send/dispatch then keeps the draft / queued item rather than dropping it.
///
/// Because the model lives on the durable `LivePaneSession` (panes mount at opacity-0 and are
/// never torn down across tab switches — see memory), `draft` and the queue survive tab
/// switches; `cancel()` (`⎋`) hides the bar but keeps the draft so re-opening restores it.
///
/// ## Two-signal idle mapping (`notePromptIdle()`)
///
/// otty has ONE "next idle prompt" dispatch trigger. aislopdesk has no single equivalent
/// because Claude Code runs in the **alt-screen** (it emits no OSC-133 prompt marks) while a
/// normal shell does, so the trigger is the **union of two faithful signals**, resolved
/// per-pane, both funnelling into ``notePromptIdle()`` → one ``PromptQueueModel/dispatchNext()``
/// per idle:
///
/// 1. **Normal terminal pane** → the client `modeTracker` emits OSC-133 `;A` (`.promptStart`)
///    when the shell is back at an idle prompt (`TerminalViewModel.onPromptIdle`). This is the
///    literal otty trigger.
/// 2. **Agent (alt-screen) pane** → `claudeStatus` transitions to `.idle` (host-detected,
///    wired through `LivePaneSession.feedAgentSignal`). This is the faithful equivalent of
///    "the agent went idle between turns".
///
/// Both paths call ``notePromptIdle()``; the queue dispatches FIFO, one item per idle.
@preconcurrency
@MainActor
@Observable
public final class ComposerModel {
    /// The composer's editable text (bound to the multi-line field). Multi-line: bare
    /// `↩`/`⇧↩` insert newlines in the view; only `⌘↩` (``sendDraft()``) submits.
    public var draft: String = ""

    /// Whether the composer bar is shown at the pane bottom. Flipped by ``open()`` /
    /// ``toggle()`` / ``cancel()``; `private(set)` so visibility only changes through the verbs.
    public private(set) var isVisible: Bool = false

    /// Pinned — promotes the composer to a window-level mount so it rides along across tab
    /// switches (E12 WI-6). Plain view state; toggled by the pin button. Persisted via the
    /// `composerPinned` client pref.
    public var isPinned: Bool = false

    /// Floating — presents the composer in a non-activating `NSPanel` (macOS) / bottom-sheet
    /// (iOS) detached from the pane bottom (E12 WI-6). Plain view state; toggled by the float
    /// button. The SAME model backs the float, so `⌘↩` still injects into the origin pane.
    /// Sending (``sendDraft()``) or cancelling (``cancel()``) docks the float back (clears this)
    /// — the otty "sending or closing the float docks it back into the pane" rule; pinning is
    /// independent (a pinned composer stays pinned across a cancel).
    public var isFloating: Bool = false

    /// The owned Prompt Queue (`⌘⇧M`). Mutated only through the model's chip verbs
    /// (``enqueueDraft()`` / ``editChip(id:)`` / ``removeChip(id:)`` / ``moveChip(from:to:)``)
    /// and drained by ``notePromptIdle()``; the strip reads `promptQueue.items` and its
    /// `isEmpty` for hidden-when-empty.
    public private(set) var promptQueue = PromptQueueModel()

    /// The single OUT sink. Every composer/queue byte funnels SYNCHRONOUSLY through here, on
    /// the main actor, in call order — wired by `LivePaneSession` to the pane's
    /// `InputBarModel.sendText`/`sendRaw` so composer bytes ride the SAME per-pane ordered-OUT
    /// FIFO + B1 echo-dedup ring as renderer keystrokes (docs/29). `nil` while the pane is
    /// disconnected — a send/dispatch then keeps the draft / queued item instead of dropping
    /// it. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var send: ((Data) -> Void)?

    public init(send: ((Data) -> Void)? = nil) {
        self.send = send
    }

    // MARK: Visibility — ⌘⇧E (open/toggle) / ⎋ (cancel)

    /// Shows the composer (`⌘⇧E` when hidden, and the paste / queue-open entry points).
    /// Idempotent; never clears the draft.
    public func open() {
        isVisible = true
    }

    /// Flips visibility (`⌘⇧E`). Returns the new value so a caller can update a toggle's
    /// active state in one hop. Hiding via toggle keeps the draft (same as ``cancel()``).
    @discardableResult
    public func toggle() -> Bool {
        isVisible.toggle()
        return isVisible
    }

    /// Hides the composer but **keeps the draft** (`⎋`). The draft survives because the model
    /// lives on the durable `LivePaneSession`, so a later ``open()`` restores it verbatim. Also
    /// docks a floating composer back into the pane (clears ``isFloating``) — closing the float
    /// returns it home (E12 WI-6); ``isPinned`` is left untouched (a pinned composer stays pinned).
    public func cancel() {
        isVisible = false
        isFloating = false
    }

    // MARK: Submit — ⌘↩ (send) / ⌥⌘↩ (enqueue)

    /// Sends the draft and closes (`⌘↩` — send + clear + close). A SINGLE-line draft emits
    /// `UTF-8(draft) + CR` (`0x0D`) — byte-identical to a typed line. A MULTI-line draft is
    /// wrapped in DEC bracketed-paste markers (``PasteTransform/bracketed(_:)`` →
    /// `ESC[200~ … ESC[201~`) *before* the trailing CR, so its embedded `\n` bytes stay INERT
    /// and the whole prompt lands as ONE block instead of fragmenting into a command/turn per
    /// line (a raw `\n` submits early — a shell runs each line, the Claude Code TUI fires on the
    /// first). The client adds the markers; the host never does — mirroring the existing paste
    /// path. It then clears the draft and hides. A blank / whitespace-only / bare-newline draft
    /// is a no-op (nothing is sent and the draft is left untouched). With no sink (disconnected)
    /// the draft is preserved. On a real send it also docks a floating composer back (clears
    /// ``isFloating``) — the otty "sending docks the float back into the pane" rule; ``isPinned``
    /// is unaffected.
    public func sendDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let send else { return } // disconnected — keep the draft for a reconnect.
        // A multi-line draft rides as one inert DEC bracketed-paste block so embedded newlines
        // stay live-input-inert; a single-line draft is byte-identical to a typed line.
        let payload = draft.contains(where: \.isNewline) ? PasteTransform.bracketed(draft) : draft
        var bytes = Data(payload.utf8)
        bytes.append(0x0D) // CR — submit (after the END marker for a paste), like Enter at the prompt.
        send(bytes)
        draft = ""
        isVisible = false
        isFloating = false
    }

    /// Appends the draft to the queue and clears it, **staying open** (`⌥⌘↩`). Splits the draft
    /// into one queue item per non-blank line (``PromptQueueModel/enqueue(_:)``). Sends
    /// **nothing** now — queued items dispatch later, one per idle, via ``notePromptIdle()``.
    public func enqueueDraft() {
        promptQueue.enqueue(draft)
        draft = ""
        isVisible = true
    }

    // MARK: Paste — ⌘V (rich → Markdown) / ⇧⌘V (plain)

    /// Inserts already-converted Markdown into the draft and opens the composer (`⌘V` rich
    /// paste / the context-menu "Paste and continue in Composer" seam). The HTML/RTF→Markdown
    /// conversion runs at the view call site (`RichPasteMarkdown`, E12 WI-2) against the
    /// platform pasteboard; the model just receives the resulting string.
    public func pasteRich(_ markdown: String) {
        insert(markdown)
    }

    /// Inserts verbatim plain text into the draft and opens the composer (`⇧⌘V`).
    public func pastePlain(_ text: String) {
        insert(text)
    }

    /// Shared paste body: append to the current draft and reveal the composer. The view's
    /// in-field `⌘V` inserts at the caret; this model-level path (the context-menu seam, which
    /// has no caret) appends, so a paste into a non-empty draft is non-destructive.
    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        draft += text
        isVisible = true
    }

    // MARK: Queue chips — tap-edit / ✕-remove / drag-reorder

    /// Pops the chip with `id` back into the composer for editing (tap-to-edit). Loads the
    /// item's text into the draft and opens the composer; the item leaves the queue (it's
    /// re-added on the next ``enqueueDraft()``). Unknown id is a no-op.
    public func editChip(id: PromptQueueItem.ID) {
        guard let text = promptQueue.take(id: id) else { return }
        draft = text
        isVisible = true
    }

    /// Removes the chip with `id` from the queue without dispatching it (the chip's `✕`).
    public func removeChip(id: PromptQueueItem.ID) {
        promptQueue.removeItem(id: id)
    }

    /// Reorders a chip from `source` to the final index `destination` (drag-to-reorder).
    /// Out-of-range / no-op moves are dropped silently by ``PromptQueueModel/move(from:to:)``.
    public func moveChip(from source: Int, to destination: Int) {
        promptQueue.move(from: source, to: destination)
    }

    // MARK: Idle dispatch — the single sink BOTH idle signals call

    /// Dispatches the next queued prompt at an idle boundary (see the two-signal mapping in the
    /// type doc). Pops the head item and writes its bytes (`UTF-8(text) + CR`) through ``send``,
    /// one item per call, FIFO. A no-op when the queue is empty. With no sink (disconnected) the
    /// queue is left intact so nothing is lost.
    public func notePromptIdle() {
        guard let send else { return } // disconnected — keep the queued items.
        guard let bytes = promptQueue.dispatchNext() else { return }
        send(bytes)
    }
}
