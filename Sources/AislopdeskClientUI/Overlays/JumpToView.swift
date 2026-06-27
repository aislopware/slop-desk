// JumpToView — the floating Jump-To panel (E10 / WI-8, ES-E10-5), opened by ⌘J. A centered, SCRIMMED
// quick-switcher over the FOCUSED pane (`jump-to.png`): a pre-focused search field, then a fuzzy-filtered
// list of the pane's detected paths/URLs (over its scrollback, via `TerminalLinkDetector`) + its OSC-133
// command/prompt index (`TerminalBlockModel`), each row carrying a leading kind icon, the title, a relative
// timestamp, and a type badge (Path / URL / File / Cmd / Prompt). ↩ acts on the selected row, ⌘K opens the
// per-row Actions popover (the SAME `LinkActionPolicy` / `TerminalContextMenu` item set the renderer uses),
// Esc closes.
//
// SEAM discipline: the PURE assembly + filtering live in `JumpToModel` (headlessly tested); this view only
// snapshots the focused pane on appear, ranks via the vendored `FuzzyMatcher` (injected into
// `JumpToModel.filtered`), and dispatches the chosen `Act`. A link `Act` resolves through the pure
// `LinkActionPolicy` and actuates with the same thin platform dispatch the renderer's `performLinkAction`
// uses (copy → pasteboard, cd → verbatim-UTF-8 PTY, open/reveal → the host RPC callbacks, URL → client
// open); a block `Act` jumps the scrollback via `WorkspaceStore.jumpToNavigatorBlockInActivePane`.
//
// The scrim, centering, and fade-in are added by the `OverlayHostView` that mounts this; JumpToView IS the
// panel. `Otty.*` tokens ONLY (raw font/colour/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct JumpToView: View {
    /// The live store — resolves the FOCUSED pane (its terminal model + last-known cwd) and performs the
    /// scrollback jump for a command/prompt row.
    let store: WorkspaceStore
    /// The single overlay reducer — closes this panel on Esc / row act / scrim tap.
    let coordinator: OverlayCoordinator

    /// The query field text. Editing it re-filters (cheap) the snapshot + resets the selection to row 0.
    @State private var query = ""
    /// The focused pane's rows, SNAPSHOTTED once on appear (running the detector over the whole scrollback
    /// is not per-keystroke work). The filter then runs over this in-memory list.
    @State private var allItems: [JumpToItem] = []
    /// The keyboard-selected row index into ``filteredItems``.
    @State private var selection = 0
    /// Whether the ⌘K Actions popover is shown for the selected row.
    @State private var actionsVisible = false

    /// Pre-focuses the search field on appear so typing reaches it immediately (otty parity).
    @FocusState private var searchFocused: Bool

    // The fixed panel width + results viewport cap (jump-to.png: a compact centered card, ~480pt).
    private let panelWidth: CGFloat = 520
    private let resultsMaxHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            resultsList
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            footerBar
        }
        .frame(width: panelWidth)
        .background(Otty.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard)
                .stroke(Otty.Line.card, lineWidth: Otty.Metric.hairline),
        )
        .shadow(color: Otty.State.shadow, radius: 30, x: 0, y: 12)
        .onAppear { snapshotItems() }
        .onChange(of: query) { _, _ in
            selection = 0
            actionsVisible = false
        }
        // Keyboard: the app NSEvent monitor passes bare arrows/Return through (it swallows only the prefix +
        // bound chords), so they reach this focused overlay. ⌘J (a BOUND chord) re-toggles to close via the
        // dispatcher; ⌘K is unbound so it lands on the handler below.
        .onKeyPress(.upArrow, phases: .down) { _ in
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            moveSelection(1)
            return .handled
        }
        // Plain ↩ acts via the field's `.onSubmit` (TextField-native, reliable — the palette idiom); no
        // container Return handler, so a single ↩ never double-fires (onSubmit + onKeyPress).
        // ⌘K toggles the per-row Actions popover (jump-to.png "Actions ⌘K"). The focused field consumes a
        // bare "k"; only ⌘K (which the field ignores) reaches this container handler — the palette's ⌘↩ idiom.
        .onKeyPress(KeyEquivalent("k"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if !filteredItems.isEmpty { actionsVisible.toggle() }
            return .handled
        }
        #if os(macOS)
        .onExitCommand { close() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            close()
            return .handled
        }
        #endif
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            TextField("Search commands, URLs, files…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
                .focused($searchFocused)
                .onSubmit { actSelected() } // plain ↩ acts + closes
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / find-bar idiom).
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = filteredItems
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                }
                .padding(.vertical, Otty.Metric.space1)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: selection) { _, _ in
                let rows = filteredItems
                guard selection >= 0, selection < rows.count else { return }
                withAnimation(Otty.Anim.smallFade) { proxy.scrollTo(rows[selection].id, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        Text(allItems.isEmpty ? "Nothing to jump to yet" : "No matches")
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Otty.Metric.space4)
    }

    private func row(_ item: JumpToItem, index: Int) -> some View {
        let isSelected = index == selection
        return HStack(spacing: Otty.Metric.space2) {
            Image(systemName: item.symbol)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                .frame(width: 16, alignment: .center)
            highlightedTitle(item)
                .font(.system(size: Otty.Typeface.body))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Otty.Metric.space2)
            if let stamp = item.timestamp {
                Text(OutlinePresentation.relativeTime(from: stamp, now: Date()))
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
                    .monospacedDigit()
            }
            badge(item.badge)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusItem)
                .fill(isSelected ? Otty.State.selected : Color.clear),
        )
        .padding(.horizontal, Otty.Metric.space2)
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selection = index } }
        .onTapGesture { act(item) }
        .id(item.id)
        // The Actions popover anchors on the SELECTED row (⌘K), reusing the link/block action item set.
        .popover(isPresented: Binding(
            get: { actionsVisible && isSelected },
            set: { if !$0 { actionsVisible = false } },
        )) {
            actionsPopover(for: item)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Otty.Typeface.small, weight: .medium))
            .foregroundStyle(Otty.Text.secondary)
            .padding(.horizontal, Otty.Metric.space1)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                    .fill(Otty.Surface.element),
            )
    }

    // MARK: - Title highlight (fzf ranges)

    /// The row title with the fzf-matched runs tinted the accent colour + semibold (the palette idiom).
    private func highlightedTitle(_ item: JumpToItem) -> Text {
        let title = item.title
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ranges = FuzzyMatcher.score(trimmed, title)?.ranges, !ranges.isEmpty else {
            return Text(title).foregroundStyle(Otty.Text.primary)
        }
        var segments: [Text] = []
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(Text(title[cursor..<range.lowerBound]).foregroundStyle(Otty.Text.primary))
            }
            segments.append(Text(title[range]).foregroundStyle(Otty.State.accent).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            segments.append(Text(title[cursor...]).foregroundStyle(Otty.Text.primary))
        }
        return segments.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - Footer bar (Quick Select ⌘ · Open ↩ · Actions ⌘K)

    private var footerBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            footerHint("Quick Select", glyph: "⌘")
            Spacer(minLength: Otty.Metric.space2)
            footerHint("Open", glyph: "↩")
            footerHint("Actions", glyph: "⌘K")
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 34)
    }

    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            Text(label)
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
            Text(glyph)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                        .fill(Otty.Surface.element),
                )
        }
    }

    // MARK: - Actions popover (⌘K / right-click — the per-row action set)

    private func actionsPopover(for item: JumpToItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rowActions(for: item).enumerated()), id: \.offset) { _, action in
                Button {
                    action.run()
                    close()
                } label: {
                    HStack(spacing: Otty.Metric.space2) {
                        Image(systemName: action.symbol)
                            .frame(width: 16)
                        Text(action.title)
                            .font(.system(size: Otty.Typeface.body))
                        Spacer(minLength: Otty.Metric.space3)
                    }
                    .foregroundStyle(Otty.Text.primary)
                    .padding(.horizontal, Otty.Metric.space3)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Otty.Metric.space1)
        .frame(minWidth: 200)
        .background(Otty.Surface.card)
    }

    /// One row in the Actions popover.
    private struct RowAction {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    /// The per-row action set — the link item set (`TerminalContextMenu.linkItems`) for a link, or Jump-to +
    /// Copy for a command/prompt block (mirroring the Outline row menu).
    private func rowActions(for item: JumpToItem) -> [RowAction] {
        switch item.act {
        case let .link(link):
            TerminalContextMenu.linkItems(for: link.kind).map { linkItem in
                RowAction(title: linkItem.title(for: link.kind), symbol: linkItem.symbol) {
                    actuate(LinkActionPolicy.action(for: linkItem, link: link))
                }
            }
        case let .block(index):
            [
                RowAction(title: "Jump to", symbol: "arrow.right.to.line") {
                    store.jumpToNavigatorBlockInActivePane(index: index)
                },
                RowAction(title: "Copy", symbol: "doc.on.doc") {
                    copyToPasteboard(item.title)
                },
            ]
        }
    }

    // MARK: - Snapshot + filter

    /// The focused pane's terminal model (its scrollback + block index live here), or `nil` when no pane is
    /// focused / it is not a live terminal (headless / placeholder / preview).
    private var activeModel: TerminalViewModel? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.terminalModel
    }

    /// The focused pane's last-known cwd (OSC 7), used to resolve relative detected paths. Empty ⇒ nil.
    private var activeCwd: String? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let cwd = store.tree.activeSession?.specs[id]?.lastKnownCwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Snapshot the focused pane into ``allItems`` ONCE on appear: run the link detector over its scrollback
    /// (only when link detection is enabled) + map its OSC-133 index, then assemble via the pure model.
    private func snapshotItems() {
        guard let model = activeModel else {
            allItems = []
            return
        }
        let rows = model.searchScrollbackLines()
        let links: [DetectedLink] = SettingsKey.linkDetectionEnabled
            ? TerminalLinkDetector.detect(rows: rows, cwd: activeCwd, schemes: SettingsKey.linkSchemePolicy)
            : []
        let blocks = model.blocks.navigatorBlocks.map { block in
            BlockSummary(
                index: block.index,
                commandText: block.commandText,
                isPrompt: false,
                firstSeen: model.blocks.firstSeen(index: block.index),
            )
        }
        allItems = JumpToModel.items(links: links, blocks: blocks)
    }

    /// The filtered + ranked rows — the vendored `FuzzyMatcher` injected into the pure `JumpToModel.filtered`.
    private var filteredItems: [JumpToItem] {
        JumpToModel.filtered(allItems, query: query) { q, h in FuzzyMatcher.score(q, h)?.score }
    }

    // MARK: - Act

    private func moveSelection(_ delta: Int) {
        let n = filteredItems.count
        guard n > 0 else { selection = 0
            return
        }
        selection = max(0, min(n - 1, selection + delta))
    }

    /// Act on the keyboard-selected row (↩), if any.
    private func actSelected() {
        let rows = filteredItems
        guard selection >= 0, selection < rows.count else { return }
        act(rows[selection])
    }

    /// Run a row's default action: a command/prompt jumps the scrollback; a link OPENS. ↩ is an EXPLICIT open
    /// intent (the footer reads "Open ↩"), so it routes through the config-INDEPENDENT
    /// ``LinkActionPolicy/explicitOpenAction`` — NOT the configurable ⌘click gesture, which would silently
    /// copy / no-op under `link-cmd-click = copy/nothing` (the E10 review bug). The ⌘K Actions popover keeps
    /// the per-item menu set (`rowActions`), which is already config-independent.
    private func act(_ item: JumpToItem) {
        switch item.act {
        case let .block(index):
            store.jumpToNavigatorBlockInActivePane(index: index)
        case let .link(link):
            actuate(LinkActionPolicy.explicitOpenAction(link: link))
        }
        close()
    }

    private func close() { coordinator.closeJumpTo() }

    /// Actuate a resolved ``LinkAction`` — the thin platform dispatch behind the pure ``LinkActionPolicy``,
    /// mirroring the renderer's `performLinkAction`: copy → client pasteboard; cd → **verbatim UTF-8**
    /// `cd <quoted>` down the active pane's PTY (never `SendKeysParser`); open/reveal → the host RPC
    /// callbacks on the model; URL → client open. A no-op when no live model backs an open/reveal/cd.
    private func actuate(_ action: LinkAction) {
        switch action {
        case .nothing:
            return
        case let .copyPathClient(text):
            copyToPasteboard(text)
        case let .changeDirectoryPTY(path):
            activeModel?.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(path).utf8))
        case let .openURLClient(urlString):
            guard let url = URL(string: urlString) else { return }
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        case let .openHost(path):
            activeModel?.onRequestOpenHostPath?(path)
        case let .revealHost(path):
            activeModel?.onRequestRevealHostPath?(path)
        }
    }

    /// Copy text to the platform pasteboard (the Outline row "Copy" idiom). A no-op for empty text.
    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
#endif
