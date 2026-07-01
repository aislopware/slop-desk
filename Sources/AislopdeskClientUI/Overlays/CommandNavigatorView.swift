// CommandNavigatorView — the Command Navigator overlay (E10 / WI-10, G8), opened by ⌃⌘O over the ACTIVE
// pane (`view.commandNavigator` → `requestBlockNavigatorInActivePane` → the pane model's
// `onRequestBlockNavigator`, toggled by `TerminalLeafView`). A scrimmed, centered card floating over the
// pane's terminal surface: a pre-focused search field, a status segment (All | Failed | Bookmarked), then a
// fuzzy-filtered list of the pane's recent OSC-133 command blocks (newest-first), each row carrying a left
// exit-status gutter (green ✓ / red ✗ / grey ·, via `OutlinePresentation.gutter`), the command text, an
// optional duration + relative timestamp, and a star toggle. ↑/↓ move the selection, ↩ jumps the scrollback
// to the selected command and closes, Esc / scrim-tap closes.
//
// DISTINCT from Jump-To (`JumpToView`, ⌘J): Jump-To lists links + commands + actions across the whole pane;
// the Navigator is a BLOCK/command jump WITHIN the pane. The PURE assembly + filtering live in
// `CommandNavigatorModel` (headlessly tested, mirroring `JumpToModel`); this view snapshots nothing — it
// reads the LIVE per-pane `TerminalBlockModel` so new commands appear as they run (a live-updating index) — ranks
// via the vendored `FuzzyMatcher` (injected into `CommandNavigatorModel.filtered`), and jumps via
// `WorkspaceStore.jumpToNavigatorBlockInActivePane(index:)` (the shared `BlockJump` re-anchor engine, so the
// delta math is never re-derived here). The navigator only ever opens over the ACTIVE pane, so the store's
// active-pane jump always re-anchors the pane this card floats over.
//
// `Slate.*` tokens ONLY (raw font/colour/radius literals fail `scripts/check-ds-leaks.sh`). Cross-platform:
// the ⌃⌘O chord is macOS-only, but the overlay + its keyboard handling compile for iOS too (the toolbar /
// menu surfaces it there), so this whole file builds under `bash scripts/check-ios.sh`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SFSafeSymbols
import SwiftUI

/// Per-pane chrome holder driving the Command Navigator's visibility — a reference type so the pane model's
/// `onRequestBlockNavigator` `@MainActor` closure can TOGGLE it (the seam doc: "show/hide"), exactly like the
/// find bar's ``TerminalFindBarModel`` / the Composer's ``ComposerLeafChrome``. Held as `@State` on the
/// `.id(PaneID)`-keyed ``TerminalLeafView``, so it is per-pane (no cross-pane bleed) and never the durable
/// model's concern.
@MainActor
@Observable
final class CommandNavigatorChrome {
    /// Whether the navigator card is mounted over this pane. Toggled by `onRequestBlockNavigator` (⌃⌘O),
    /// cleared by the card's Esc / scrim-tap / row-jump.
    var isVisible = false
}

struct CommandNavigatorView: View {
    /// The pane's live terminal model — its pure block store (`blocks`) is the navigator's data source, and
    /// its bookmarks API backs the star toggle. This is the pane THIS card floats over (the active pane).
    let model: TerminalViewModel
    /// The live store — performs the scrollback jump for the chosen command via the shared `BlockJump` engine
    /// (`jumpToNavigatorBlockInActivePane`, resolving the active pane = the pane this card is over).
    let store: WorkspaceStore
    /// Closes the navigator (clears the pane chrome's `isVisible`). Called on Esc / scrim-tap / a row jump.
    let onClose: () -> Void

    /// The query field text. Editing it re-filters (cheap) the live block list + resets the selection to 0.
    @State private var query = ""
    /// The status segment (All | Failed | Bookmarked) — the pure ``BlockNavigatorFilter`` the model queries.
    @State private var filter: BlockNavigatorFilter = .all
    /// The keyboard-selected row index into ``visibleBlocks``.
    @State private var selection = 0
    /// Pre-focuses the search field on appear so typing reaches it immediately (the Jump-To / palette idiom).
    @FocusState private var searchFocused: Bool

    // The fixed panel width + results viewport cap (a compact centered card, the Jump-To family geometry).
    private let panelWidth: CGFloat = 480
    private let resultsMaxHeight: CGFloat = 320

    var body: some View {
        ZStack {
            // Pane-LOCAL dimmed backdrop (the navigator floats over THIS pane's terminal, not the window, so
            // it keeps its own scrim rather than the window-level native sheet the auxiliary overlays now use).
            Rectangle()
                .fill(Slate.State.shadow)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .transition(.opacity)
            card
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            searchBar
            divider
            filterBar
            divider
            resultsList
            divider
            footerBar
        }
        .frame(width: panelWidth)
        .background(Slate.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .stroke(Slate.Line.card, lineWidth: Slate.Metric.hairline),
        )
        .shadow(color: Slate.State.shadow, radius: 30, x: 0, y: 12)
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: filter) { _, _ in selection = 0 }
        // Keyboard: the focused search field consumes typed text + plain ↩ (`onSubmit`); bare arrows / Esc
        // bubble to these container handlers (the Jump-To idiom). The ⌃⌘O chord re-toggles to close via the
        // dispatcher → the pane model's `onRequestBlockNavigator`.
        .onKeyPress(.upArrow, phases: .down) { _ in
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            moveSelection(1)
            return .handled
        }
        #if os(macOS)
        .onExitCommand { onClose() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            onClose()
            return .handled
        }
        #endif
    }

    private var divider: some View {
        Rectangle()
            .fill(Slate.Line.divider)
            .frame(height: Slate.Metric.hairline)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
            TextField("Search commands…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent) // the active caret is the accent colour
                .focused($searchFocused)
                .onSubmit { actSelected() } // plain ↩ jumps + closes
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: 48)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / find-bar / Jump-To idiom).
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Filter segment (All | Failed | Bookmarked)

    private var filterBar: some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(BlockNavigatorFilter.allCases, id: \.self) { segment in
                filterPill(segment)
            }
            Spacer(minLength: Slate.Metric.space2)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: 36)
    }

    private func filterPill(_ segment: BlockNavigatorFilter) -> some View {
        let active = segment == filter
        return Button {
            filter = segment
        } label: {
            HStack(spacing: Slate.Metric.space1) {
                Image(systemName: segment.symbol)
                    .font(.system(size: Slate.Typeface.small))
                Text(segment.title)
                    .font(.system(size: Slate.Typeface.footnote, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? Slate.Text.primary : Slate.Text.secondary)
            .padding(.horizontal, Slate.Metric.space2)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .fill(active ? Slate.Surface.element : Color.clear),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = visibleBlocks
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, block in
                            row(block, index: index)
                        }
                    }
                }
                .padding(.vertical, Slate.Metric.space1)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: selection) { _, _ in
                let rows = visibleBlocks
                guard selection >= 0, selection < rows.count else { return }
                withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(rows[selection].id, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        Text(baseBlocks.isEmpty ? emptyMessage : "No matches")
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Slate.Metric.space4)
    }

    /// The zero-state message for the empty pane, scoped to the active segment (no commands / none failed /
    /// none starred).
    private var emptyMessage: String {
        switch filter {
        case .all: "No commands yet"
        case .failed: "No failed commands"
        case .bookmarked: "No bookmarked commands"
        }
    }

    private func row(_ block: CommandBlock, index: Int) -> some View {
        let isSelected = index == selection
        return HStack(spacing: Slate.Metric.space2) {
            gutter(for: block)
                .frame(width: 14, alignment: .center)
            highlightedTitle(block)
                .font(.system(size: Slate.Typeface.body))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Slate.Metric.space2)
            if let duration = block.durationLabel {
                Text(duration)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                    .monospacedDigit()
            }
            if let stamp = model.blocks.firstSeen(index: block.index) {
                Text(OutlinePresentation.relativeTime(from: stamp, now: Date()))
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                    .monospacedDigit()
            }
            starButton(block)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                .fill(isSelected ? Slate.State.selected : Color.clear),
        )
        .padding(.horizontal, Slate.Metric.space2)
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selection = index } }
        .onTapGesture { act(block) }
        .id(block.id)
    }

    /// The status gutter glyph — green ✓ (succeeded) / red ✗ (failed) / grey · (running), via the pure
    /// ``OutlinePresentation/gutter(for:)`` classification (the Outline sidebar's exact treatment, so the
    /// two never disagree on what counts as success). The colour is the ONLY theme-coupled part.
    @ViewBuilder
    private func gutter(for block: CommandBlock) -> some View {
        switch OutlinePresentation.gutter(for: block) {
        case .succeeded:
            Image(systemSymbol: .checkmark)
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.ok)
        case .failed:
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.err)
        case .running:
            Circle()
                .fill(Slate.Text.tertiary)
                .frame(width: 5, height: 5)
        }
    }

    /// The per-row star (bookmark) toggle — drives the SAME ``TerminalBlockModel`` bookmarks API the
    /// inspector's `BlockHistoryView` star uses (so a star set in either surface shows in both + persists
    /// through the wired `onBookmarksChanged`). Reading `isBookmarked` here re-renders the glyph on toggle.
    private func starButton(_ block: CommandBlock) -> some View {
        let starred = model.blocks.isBookmarked(block.index)
        return Button {
            model.blocks.toggleBookmark(index: block.index)
        } label: {
            Image(systemSymbol: starred ? .starFill : .star)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(starred ? Slate.Status.warn : Slate.Text.tertiary)
        }
        .buttonStyle(.plain)
    }

    /// The row title with the fzf-matched runs tinted the accent colour + semibold (the Jump-To / palette
    /// idiom). A still-forming block (empty command) shows an em-dash; it can never match a real query, so it
    /// only appears in the zero-state list.
    private func highlightedTitle(_ block: CommandBlock) -> Text {
        let title = block.commandText.isEmpty ? "—" : block.commandText
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ranges = FuzzyMatcher.score(trimmed, title)?.ranges, !ranges.isEmpty else {
            return Text(title).foregroundStyle(Slate.Text.primary)
        }
        var segments: [Text] = []
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(Text(title[cursor..<range.lowerBound]).foregroundStyle(Slate.Text.primary))
            }
            segments.append(Text(title[range]).foregroundStyle(Slate.State.accent).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            segments.append(Text(title[cursor...]).foregroundStyle(Slate.Text.primary))
        }
        return segments.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - Footer hint bar

    private var footerBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            footerHint("Navigate", glyph: "↑↓")
            Spacer(minLength: Slate.Metric.space2)
            footerHint("Jump", glyph: "↩")
            footerHint("Close", glyph: "esc")
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: 34)
    }

    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.tertiary)
            Text(glyph)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .fill(Slate.Surface.element),
                )
        }
    }

    // MARK: - Data

    /// The active pane's blocks for the current status segment (newest-first), BEFORE the text filter — the
    /// pure ``TerminalBlockModel/blocks(filter:)`` query. Read LIVE (no snapshot) so a command that finishes
    /// while the navigator is open updates its gutter in place.
    private var baseBlocks: [CommandBlock] {
        model.blocks.blocks(filter: filter)
    }

    /// The filtered + ranked rows — the vendored `FuzzyMatcher` injected into the pure
    /// ``CommandNavigatorModel/filtered(_:query:score:)`` (the same split as Jump-To).
    private var visibleBlocks: [CommandBlock] {
        CommandNavigatorModel.filtered(baseBlocks, query: query) { q, h in FuzzyMatcher.score(q, h)?.score }
    }

    // MARK: - Act

    private func moveSelection(_ delta: Int) {
        let count = visibleBlocks.count
        guard count > 0 else {
            selection = 0
            return
        }
        selection = max(0, min(count - 1, selection + delta))
    }

    /// Act on the keyboard-selected row (↩), if any.
    private func actSelected() {
        let rows = visibleBlocks
        guard selection >= 0, selection < rows.count else { return }
        act(rows[selection])
    }

    /// Jump the active pane's scrollback to `block` (the shared `BlockJump` re-anchor, via the store's
    /// active-pane jump — which finds the block's CURRENT newest-first position by index, so it is robust to
    /// a command arriving / a block evicting while the navigator was open), then close.
    private func act(_ block: CommandBlock) {
        store.jumpToNavigatorBlockInActivePane(index: block.index)
        onClose()
    }
}
#endif
