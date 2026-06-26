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
/// against renderer keystrokes (docs/29). The `guard let send` in ``sendDraft()`` / ``dispatch()`` is a
/// DEFENSIVE guard for a model with **no sink wired** — a headless test, a SwiftUI preview, or a
/// never-adopted model — NOT a live in-production disconnect path: `LivePaneSession.make` wires `send`
/// once at construction and never clears it, so in production it is always non-nil. Disconnect
/// resilience is the input bar's job (the `ReplayBuffer` / ordered-OUT FIFO holds un-acked bytes); the
/// composer just hands every byte to the always-present sink in call order.
///
/// Because the model lives on the durable `LivePaneSession` (panes mount at opacity-0 and are
/// never torn down across tab switches — see memory), `draft` and the queue survive tab
/// switches; `cancel()` (`⎋`) hides the bar but keeps the draft so re-opening restores it.
///
/// ## Two-signal turn-finished mapping (`notePromptIdle()`)
///
/// otty has ONE "next idle prompt" dispatch trigger. aislopdesk has no single equivalent
/// because Claude Code runs in the **alt-screen** (it emits no OSC-133 prompt marks) while a
/// normal shell does, so the trigger is the **union of two faithful signals**, resolved
/// per-pane, both funnelling into ``notePromptIdle()`` → one ``PromptQueueModel/dispatchNext()``
/// per turn:
///
/// 1. **Normal terminal pane** → the client `modeTracker` emits OSC-133 `;A` (`.promptStart`)
///    when the shell is back at an idle prompt (`TerminalViewModel.onPromptIdle`). This is the
///    literal otty trigger.
/// 2. **Agent (alt-screen) pane** → `claudeStatus` transitions to `.done` (host-detected via the
///    Stop hook, wired through `LivePaneSession.feedAgentSignal`). `.done` is the IMMEDIATE
///    turn-finished edge (it then decays to `.idle` ~8s later); dispatching on `.done` — NOT on the
///    laggy `.idle` decay — fires each queued prompt the moment the turn actually ends.
///
/// Both paths call ``notePromptIdle()``; the queue dispatches FIFO, one item per finished turn.
///
/// ## Kickstart (`isIdleNow`)
///
/// The turn-finished EDGE only fires after a turn runs. If the user enqueues while the pane is
/// ALREADY idle (a shell sitting at its prompt, or an agent between turns), there is no edge to wait
/// for, so ``enqueueDraft()`` kickstarts exactly the head item once (guarded by ``isIdleNow`` — the
/// per-pane "idle now?" probe `LivePaneSession` injects — and a one-dispatch-per-turn in-flight latch).
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
    /// switches (E12 WI-6). Mutated ONLY through ``togglePin()`` / ``setPinned(_:)`` so a flip can
    /// notify ``onPinnedChange`` (the owner persists the pin keyed by the pane's stable `PaneID`,
    /// the otty "pinned state is persisted as a user preference" rule — see `LivePaneSession.adopt`).
    public private(set) var isPinned: Bool = false

    /// Fired when ``isPinned`` actually changes (not on a no-op set), so the owning
    /// ``LivePaneSession`` can persist the per-pane pin. Wired AFTER the persisted pin is restored, so
    /// the restore itself never re-persists. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onPinnedChange: ((Bool) -> Void)?

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
    /// FIFO + B1 echo-dedup ring as renderer keystrokes (docs/29). In production this is wired once
    /// at `LivePaneSession.make` and stays non-nil for the pane's life (it does not go nil on a
    /// transport disconnect — the input bar / `ReplayBuffer` absorbs that); `nil` only for a model with
    /// no sink (headless test / preview / never-adopted), where the `guard let send` keeps the
    /// draft / queued item instead of trapping. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var send: ((Data) -> Void)?

    /// The caret / selection in ``draft`` as a UTF-16 range (matching `NSTextView`/`UITextView`
    /// `selectedRange`). The hosted text view (`ComposerTextView`, an `NSTextView`/`UITextView` subclass in
    /// `AislopdeskClientUI`) mirrors its `selectedRange` here on every selection change so a paste — both
    /// the in-field `⌘V` and the right-click "Paste and continue in Composer" seam (which has no live
    /// responder) — splices at the caret via ``insert(_:at:)`` instead of appending. `nil` ⇒ no live caret
    /// yet ⇒ append at the end of ``draft`` (a fresh, never-focused composer). `@ObservationIgnored`: the
    /// view WRITES this, so it must not invalidate the field mid-edit.
    @ObservationIgnored public var selection: NSRange?

    /// Per-pane "is the owning pane idle RIGHT NOW?" probe, injected by ``LivePaneSession`` (true when the
    /// normal shell is at its prompt OR the agent is between turns — `claudeStatus` `.idle`/`.done`). Read by
    /// the ``enqueueDraft()`` kickstart so the FIRST queued prompt fires immediately when the pane is already
    /// idle (no turn-finished edge will ever come for it otherwise). `nil` (headless / preview) ⇒ never idle ⇒
    /// no kickstart. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var isIdleNow: (() -> Bool)?

    /// One-dispatch-per-turn latch: set when a prompt is dispatched (kickstart OR turn-finished edge), cleared
    /// by the next turn-finished edge. Guards the kickstart from sending a second prompt while one is already
    /// in flight for the current turn (e.g. a status that still reads idle for a beat after a kickstart).
    private var dispatchInFlight = false

    public init(send: ((Data) -> Void)? = nil) {
        self.send = send
    }

    // MARK: Pin — togglePin() / setPinned(_:) (notifies onPinnedChange for per-pane persistence)

    /// Toggles the pin (the toolbar pin button). Routes through ``setPinned(_:)`` so the flip notifies
    /// ``onPinnedChange`` (the owner persists the per-pane pin).
    public func togglePin() { setPinned(!isPinned) }

    /// Sets the pin, notifying ``onPinnedChange`` only on a REAL change. Used by ``togglePin()``, by the iOS
    /// sheet-dismiss dock-back, and by ``LivePaneSession``'s persisted-pin restore (which wires
    /// ``onPinnedChange`` AFTER calling this, so restoring the pin never re-persists it).
    public func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else { return }
        isPinned = pinned
        onPinnedChange?(pinned)
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
    /// is a no-op (nothing is sent and the draft is left untouched). With no sink wired (a
    /// headless/preview model — see ``send``) the draft is preserved. On a real send it also docks a floating composer back (clears
    /// ``isFloating``) — the otty "sending docks the float back into the pane" rule; ``isPinned``
    /// is unaffected.
    public func sendDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let send else { return } // DEFENSIVE: no sink wired (headless/preview) — keep the draft. In
        // production `send` is always wired, so this never fires; a transport disconnect is absorbed by the
        // input bar / ReplayBuffer downstream, not by nilling this sink.
        // A multi-line draft rides as one inert DEC bracketed-paste block so embedded newlines
        // stay live-input-inert; a single-line draft is byte-identical to a typed line.
        let payload = draft.contains(where: \.isNewline) ? PasteTransform.bracketed(draft) : draft
        var bytes = Data(payload.utf8)
        bytes.append(0x0D) // CR — submit (after the END marker for a paste), like Enter at the prompt.
        send(bytes)
        draft = ""
        selection = nil
        isVisible = false
        isFloating = false
    }

    /// Appends the draft to the queue and clears it, **staying open** (`⌥⌘↩`, and the `⌘⇧M` add-a-line
    /// path). Splits the draft into one queue item per non-blank line (``PromptQueueModel/enqueue(_:)``).
    /// Sends nothing for a BUSY pane — queued items dispatch later, one per finished turn, via
    /// ``notePromptIdle()``. But if the owning pane is ALREADY idle (``isIdleNow``), it KICKSTARTS exactly
    /// the head item now (no turn-finished edge is coming for it), then the rest wait for edges.
    public func enqueueDraft() {
        promptQueue.enqueue(draft)
        draft = ""
        selection = nil
        isVisible = true
        kickstartIfIdle()
    }

    /// Kickstart: dispatch the head queued item once IF the pane is idle now and no prompt is already in
    /// flight for this turn. A no-op when busy (the turn-finished edge will drive dispatch) or when a
    /// kickstart/edge dispatch is already in flight (the in-flight latch prevents a double-send).
    private func kickstartIfIdle() {
        guard !dispatchInFlight, isIdleNow?() == true else { return }
        dispatch()
    }

    // MARK: Paste — ⌘V (rich → Markdown) / ⇧⌘V (plain)

    /// Inserts already-converted Markdown AT THE CARET and opens the composer (`⌘V` rich paste / the
    /// right-click "Paste and continue in Composer" seam). The HTML/RTF→Markdown conversion runs at the
    /// view call site (`RichPasteMarkdown`, E12 WI-2) against the platform pasteboard; the model receives
    /// the resulting string and splices it at the current ``selection`` (replacing any selected text).
    public func pasteRich(_ markdown: String) {
        insert(markdown)
    }

    /// Inserts verbatim plain text AT THE CARET and opens the composer (`⇧⌘V`).
    public func pastePlain(_ text: String) {
        insert(text)
    }

    /// Caret-aware insert: splices `text` into ``draft`` at `range` (UTF-16, replacing any selected text),
    /// reveals the composer, and advances the caret to the end of the inserted text. `range` defaults to the
    /// live ``selection`` (the in-field `⌘V` passes the field's fresh range; the context-menu path uses the
    /// last-known caret the coordinator reported). A `nil` range / selection ⇒ append at the end of the draft
    /// (a fresh, never-focused composer). Validate-then-degrade: an out-of-bounds or grapheme-splitting range
    /// is clamped, and any range that still fails to map to a `String` index falls back to an append — never
    /// a trap.
    public func insert(_ text: String, at range: NSRange? = nil) {
        guard !text.isEmpty else { return }
        isVisible = true
        let length = draft.utf16.count
        let endRange = NSRange(location: length, length: 0)
        let target = Self.clamp(range ?? selection ?? endRange, toLength: length)
        guard let swiftRange = Range(target, in: draft) else {
            draft += text
            selection = NSRange(location: draft.utf16.count, length: 0)
            return
        }
        draft.replaceSubrange(swiftRange, with: text)
        selection = NSRange(location: target.location + text.utf16.count, length: 0)
    }

    /// Clamp an NSRange into `0...length` (location and length both), so a stale UI selection can never index
    /// past the draft. Ordered comparisons (no NaN here — integer offsets).
    private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let maxLen = length - location
        return NSRange(location: location, length: min(max(range.length, 0), maxLen))
    }

    // MARK: Queue chips — tap-edit / ✕-remove / drag-reorder

    /// Pops the chip with `id` back into the composer for editing (tap-to-edit). Loads the
    /// item's text into the draft and opens the composer; the item leaves the queue (it's
    /// re-added on the next ``enqueueDraft()``). Unknown id is a no-op.
    public func editChip(id: PromptQueueItem.ID) {
        guard let text = promptQueue.take(id: id) else { return }
        draft = text
        selection = nil
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

    // MARK: Turn-finished dispatch — the single sink BOTH turn-finished signals call

    /// Dispatches the next queued prompt at a turn-finished edge (see the two-signal mapping in the type
    /// doc): the normal-pane OSC-133;A prompt mark, or the agent-pane `claudeStatus → .done` transition. The
    /// finished turn clears the in-flight latch, then the head item (if any) is dispatched, one item per
    /// edge, FIFO. A no-op when the queue is empty. With no sink wired (headless/preview) the queue is left intact so
    /// nothing is lost.
    public func notePromptIdle() {
        dispatchInFlight = false // the turn that was in flight (if any) finished.
        dispatch()
    }

    /// Pops the head queued item and writes its bytes (`UTF-8(text) + CR`) through ``send``, latching
    /// in-flight so a kickstart can't double-send. Shared by ``notePromptIdle()`` (turn-finished edge) and
    /// the ``enqueueDraft()`` kickstart. A no-op (no latch) when the queue is empty or there is no sink.
    private func dispatch() {
        guard let send else { return } // DEFENSIVE: no sink wired (headless/preview) — keep the queued
        // items. Always non-nil in production (wired once at `LivePaneSession.make`), so this never fires.
        guard let bytes = promptQueue.dispatchNext() else { return }
        dispatchInFlight = true
        send(bytes)
    }
}
