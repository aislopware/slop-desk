// CommandNavigatorSelection — the Command Navigator's SELECTION and its five verbs, once.
//
// The card has two renderers (`MacCommandNavigatorCardView`, `PhoneCommandNavigatorCardView`) and
// had two copies of everything between the block store and the pixels: the segment, the query, the
// clamped cursor, the reveal arbiter, and the jump / re-run / copy / star it fires. None of that is
// AppKit or UIKit — it is index arithmetic over `TerminalBlockModel` plus four `WorkspaceStore`
// calls — so it lives here and each shell keeps only its drawing (docs/56 §3, CLAUDE.md's "one
// implementation, never two languages").
//
// The shape is the one ``OverlayCoordinator`` and ``HoverSelectionGate`` already use on this floor:
// a `@MainActor` class holding no view type, whose mutations end in ``didChange`` so the renderer
// redraws instead of being reached into.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - What one row is drawn from

/// Everything one navigator row needs for one draw, cut in a single pass over the store.
///
/// A VALUE rather than six arguments, because the six were re-typed at both renderers and a seventh
/// would have had to be added twice. The row reads it and sets its own labels; nothing here is a
/// view, a font or a colour.
package struct CommandNavigatorRowReading: Sendable {
    /// The command this row shows.
    package let block: CommandBlock
    /// Its position in the drawn list — what a hover reports back as the new selection.
    package let index: Int
    /// Whether the keyboard (or the pointer) is on this row: the plate, the heavier command line and
    /// the two affordances that replace the meta.
    package let selected: Bool
    /// Whether the block is bookmarked — the star's latch.
    package let starred: Bool
    /// When the block was first seen, for the age half of the meta line.
    package let firstSeen: Date?
    /// The live query, so the row can mark the runs it matched.
    package let query: String
}

/// The five verbs a row can fire, bound once per row rather than re-handed on every draw — a closure
/// rebuilt per keystroke is the one allocation on that path that is not a string.
///
/// Handed out by ``CommandNavigatorSelection/rowActions()`` already bound to the selection owner, so
/// neither renderer re-declares the set.
package struct CommandNavigatorRowActions {
    package let onHover: (Int) -> Void
    package let onJump: (CommandBlock) -> Void
    package let onReRun: (CommandBlock) -> Void
    package let onCopyOutput: (CommandBlock) -> Void
    package let onToggleStar: (CommandBlock) -> Void
}

// MARK: - The card's state and its verbs

/// The Command Navigator's live selection: the segment, the query, the cursor, and the four store
/// paths a chosen row can take.
///
/// ⚠️ MUTATIONS END IN ``didChange``, never in a redraw of their own. The owner sets that closure to
/// its own draw, which is what keeps the renderer the only thing that knows a row is a view.
@MainActor
package final class CommandNavigatorSelection {
    /// The pane's live terminal model — its pure block store is the data source and its bookmarks API
    /// backs the star. This is the pane the card floats over (the active one).
    package let model: TerminalViewModel
    /// The live store — performs the jump, the re-run and the output copy through the shared paths.
    package let store: WorkspaceStore
    private let onClose: () -> Void

    /// Hover→selection arbiter: a hover-driven selection must not auto-scroll, and a list scrolling
    /// under a PARKED pointer must not steal the selection. One per presentation, shared by the rows.
    package let hoverGate = HoverSelectionGate()

    /// The rows as last cut, so the keyboard verbs act on what the eye is looking at.
    package private(set) var visible: [CommandBlock] = []
    /// The keyboard cursor, always clamped into `visible` by ``ListNavigation``.
    package private(set) var selection = 0
    /// The status segment (All | Failed | Bookmarked).
    package private(set) var filter = BlockNavigatorFilter.all
    /// The query line's text, as the field last reported it.
    package private(set) var query = ""
    /// The selection the viewport was last scrolled for. `-1` is "never", which no index can be, so
    /// the first draw does not scroll a list that has not moved.
    private var lastRevealed = -1

    /// Called whenever a verb changed what the card should show. Bound by ``follow(_:drawing:)``.
    private var didChange: () -> Void = {}
    /// The live read of the block store, armed by ``follow(_:drawing:)``.
    private var arm: ObservationFollow?

    package init(
        model: TerminalViewModel, store: WorkspaceStore, onClose: @escaping () -> Void,
    ) {
        self.model = model
        self.store = store
        self.onClose = onClose
    }

    // MARK: The live read

    /// Draws `card` now, and again on every change the draw itself read.
    ///
    /// The card reads the LIVE block model rather than a snapshot, which is the whole reason this is
    /// an observation arm and not a one-shot draw: a command that finishes while the navigator is
    /// open flips its own gutter, and a command that STARTS while it is open appears.
    ///
    /// `drawing` sits inside ``ObservationFollow``'s `read` rather than in its `apply`, against that
    /// type's usual shape: the tracked block IS the draw, so the transitive reads of the draw ARE the
    /// dependency set. Split the two and the set empties — the card would draw once and then follow
    /// nothing. `apply` is empty for that reason, not by omission.
    ///
    /// The same closure becomes ``didChange``, so a verb's redraw and the model's redraw are one path.
    package func follow<Card: AnyObject>(_ card: Card, drawing: @escaping (Card) -> Void) {
        didChange = { [weak card] in
            guard let card else { return }
            drawing(card)
        }
        arm = ObservationFollow.arm(card, replacing: arm) { drawing($0) } apply: { _, _ in }
    }

    /// Drops the arm. Idempotent, and the only thing a card owns that a `deinit` could not be relied
    /// on to reach in time.
    package func stopFollowing() {
        arm?.stop()
        arm = nil
        didChange = {}
    }

    // MARK: The read

    /// Re-cuts ``visible`` from the live block store and re-clamps the cursor. Answers whether the
    /// pane has ANY blocks in the current segment before the text filter — the zero state words "the
    /// query matched nothing" and "this segment is empty" differently.
    ///
    /// Called from inside the renderer's observation arm, so the transitive reads below ARE the
    /// dependency set that re-draws the card when a command finishes or a new one starts.
    package func recut() -> Bool {
        // The pane's blocks for the active segment (newest-first) BEFORE the text filter — the pure
        // `TerminalBlockModel` query — then the shared ranking on top of it.
        let base = model.blocks.blocks(filter: filter)
        visible = CommandNavigatorModel.filtered(base, query: query)
        selection = ListNavigation.clampedSelection(
            current: selection, delta: 0, count: visible.count,
        )
        return !base.isEmpty
    }

    /// One reading per drawn row, in draw order — the star and the age asked of the store once here
    /// rather than once per renderer.
    package func rowReadings() -> [CommandNavigatorRowReading] {
        visible.enumerated().map { index, block in
            CommandNavigatorRowReading(
                block: block,
                index: index,
                selected: index == selection,
                starred: model.blocks.isBookmarked(block.index),
                firstSeen: model.blocks.firstSeen(index: block.index),
                query: query,
            )
        }
    }

    /// Whether `segment`'s pill is the lifted one.
    package func isActive(_ segment: BlockNavigatorFilter) -> Bool { segment == filter }

    /// The zero-state sentence for the current segment.
    package func emptyLine(hasBlocks: Bool) -> String {
        CommandNavigatorPresentation.emptyLine(filter: filter, hasBlocks: hasBlocks)
    }

    /// Whether the viewport should scroll to ``selection`` now — on a selection CHANGE, and for
    /// KEYBOARD navigation only.
    ///
    /// Two guards, and each answers a different way the list could move on its own. The first: a
    /// redraw the block model provoked — a command finishing, a new one starting — is not a selection
    /// change, and scrolling on it would yank the list out from under someone reading it. The second
    /// is the hover arbiter, without which the list follows the pointer: hover selects → the scroll
    /// slides a new row under the pointer → hover selects that one → forever. The arbiter is
    /// check-and-clear, so it is consumed only where a change happened.
    package func shouldReveal() -> Bool {
        guard selection != lastRevealed else { return false }
        lastRevealed = selection
        return hoverGate.shouldAutoScrollOnSelectionChange()
    }

    // MARK: Moving

    /// The clamp is ``ListNavigation``'s — the rule three overlays had each written for themselves.
    package func move(_ delta: Int) {
        selection = ListNavigation.clampedSelection(
            current: selection, delta: delta, count: visible.count,
        )
        didChange()
    }

    package func hover(_ index: Int) {
        guard selection != index else { return }
        hoverGate.noteHoverDrivenSelection()
        selection = index
        didChange()
    }

    package func choose(_ segment: BlockNavigatorFilter) {
        guard segment != filter else { return }
        filter = segment
        resetSelection()
    }

    /// The query line reported a new value.
    package func type(_ text: String) {
        guard text != query else { return }
        query = text
        resetSelection()
    }

    /// A re-filter — by query or by segment — puts the selection back on the first row AND scrolls
    /// there. `lastRevealed` is cleared rather than compared, because the selection may ALREADY be 0
    /// while the viewport is parked halfway down the previous list, and "row 0 is selected" is not the
    /// same fact as "row 0 is on screen".
    package func resetSelection() {
        selection = 0
        lastRevealed = -1
        didChange()
    }

    package func selectedBlock() -> CommandBlock? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    // MARK: Acting

    /// Jumps the active pane's scrollback to `block` — the shared `BlockJump` re-anchor via the
    /// store's active-pane jump, which finds the block's CURRENT position by index and is therefore
    /// robust to a command arriving (or a block evicting) while the card was open — then closes.
    package func act(_ block: CommandBlock) {
        store.jumpToNavigatorBlockInActivePane(index: block.index)
        onClose()
    }

    /// Re-runs `block`'s captured command verbatim in the active pane (the shared, injection-safe
    /// store path). Closes, because the re-run's output is the thing to look at. An empty command is
    /// a store-level no-op.
    package func reRun(_ block: CommandBlock) {
        guard !block.commandText.isEmpty else { return }
        store.reRunCommandInActivePane(block.commandText)
        onClose()
    }

    /// Copies `block`'s captured output (VT-stripped plain text) through the shared request path.
    /// Stays OPEN — a copy is a side action, not a jump — so the pane's own copy receipt underneath
    /// is the confirmation that a possibly huge block landed. The headless core owns no pasteboard,
    /// so the write is this floor's rather than the store's.
    package func copyOutput(_ block: CommandBlock) {
        store.copyBlockOutputInActivePane(index: block.index) { [model] text in
            guard let text, !text.isEmpty else { return }
            ClientPasteboard.write(text)
            model.noteClipboardCopy(text)
        }
    }

    /// Flips `block`'s star through the block model, which persists it via the wired
    /// `onBookmarksChanged`. The redraw comes off the renderer's observation arm, not off the click —
    /// a glyph painted here would be a mirror of the set rather than a reading of it.
    package func toggleStar(_ block: CommandBlock) {
        model.blocks.toggleBookmark(index: block.index)
    }

    /// Dismisses the card. The chord doors (Esc on both shells) come through here rather than around.
    package func close() { onClose() }

    /// The verb set a row is built with, already bound to this owner.
    package func rowActions() -> CommandNavigatorRowActions {
        CommandNavigatorRowActions(
            onHover: { [weak self] index in self?.hover(index) },
            onJump: { [weak self] block in self?.act(block) },
            onReRun: { [weak self] block in self?.reRun(block) },
            onCopyOutput: { [weak self] block in self?.copyOutput(block) },
            onToggleStar: { [weak self] block in self?.toggleStar(block) },
        )
    }
}
