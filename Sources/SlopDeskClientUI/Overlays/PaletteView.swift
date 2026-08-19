// PaletteView — the PHONE's command palette. Renders the live state of the injected
// ``OverlayCoordinator`` as a VERBS-ONLY command palette: a pre-focused search field and a
// sectioned, fzf-highlighted result list with keycap chips, a ✓ toggled-state gutter, and a keyboard-selected
// fill row. (The per-domain filter chips live in the Open-Quickly picker — ⌘⇧P shows no chips here.)
//
// THE MAC DRAWS ITS OWN (docs/56 stage D): ``SlopDeskMacUI/MacPaletteView`` is an `NSPanel` over the
// workspace window, and `MacWorkspaceRootView` drops `.palette` from this host's `draws` set so only
// one of the two is ever up. What the halves share is ``PalettePresentation`` and ``PaletteMetrics``
// — the card's measurements, the ranked rows paired with the keyboard's index, the ✓ predicate and
// the WORKING DIRECTORY badge — so neither half re-derives a decision, and each keeps only its
// arrangement.
//
// Faithful to `spec/user-interface__command-palette.md` (the centered floating panel, the magnifier +
// accent caret, ALL-CAPS section headers with the WORKING-DIRECTORY badge, keycaps, the subtle
// selected-row fill), with two deliberate departures: a chord is ONE keycap rather than one per glyph, and
// the ink is the NEUTRAL overlay palette (``SlateOverlayInk``) rather than the terminal's filter.
//
// SEAM discipline: the palette OWNS no state — every read/mutation goes through the coordinator (the single
// `@Observable` reducer) so the GUI and the headless model can't drift. Presented by ``OverlayHostView``,
// which draws it on the shared floating GLASS CARD (``SlateOverlayCard``) — so this view carries only the
// search field + result rows, and no ground, corners or shadow of its own.
//
// Section headers SURVIVE here, unlike in the ⌃⇥ switcher where they were deleted. The rule is the same in
// both places — a header earns its line only when consecutive rows share it — and the two surfaces simply
// answer it differently: the switcher's order is a recency ring, so projects interleave and a header
// degenerates into a caption per row, while the palette's results are ranked WITHIN category, so its rows
// genuinely arrive in runs. Same rule, opposite outcome.
//
// `Slate.*` for DIMENSION, ``SlateOverlayInk`` for COLOUR (raw literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct PaletteView: View {
    /// The single overlay reducer — bound so the search field can two-way edit `paletteQuery` and `body`
    /// re-renders on `paletteSelection` / `rankedResults` changes.
    @Bindable var coordinator: OverlayCoordinator
    /// The live store — read-only here, for the WORKING-DIRECTORY badge (the focused pane's `pane/cwd`).
    let store: WorkspaceStore
    /// Whether a row currently shows its ✓ (toggled-on) gutter. Built by the host from the chrome
    /// state (e.g. `id == "action.toggleSidebar" ? !chrome.sidebarCollapsed : false`) so the pure coordinator
    /// never learns about chrome. `@MainActor` so the host's closure can read the `@MainActor`
    /// ``WorkspaceChromeState`` synchronously. Defaults to "nothing toggled" for standalone mounts / previews.
    var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }

    /// Pre-focuses the search field on appear so typing reaches it immediately (spec: pre-focused on open).
    @FocusState private var searchFocused: Bool

    /// Hover→selection arbiter (see ``HoverSelectionGate``): hover-driven selection must not auto-scroll,
    /// and a list scrolling under a PARKED pointer must not steal the selection. One per presentation.
    @State private var hoverGate = HoverSelectionGate()

    /// One ⇞/⇟ stride = the rows one results viewport shows.
    private var pageStride: Int {
        PaletteMetrics.pageStride(rowHeight: Slate.Metric.heightRowTall)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            // The card's one internal line, and it is earned: results scroll UNDER the query field.
            SlateCardSeparator()
            resultsList
        }
        // The paper card is applied by `OverlayHostView`; this view carries only its content, and takes
        // the width the phone's card gives it.
        // Keyboard: the app NSEvent monitor passes bare arrows/Return through (it only swallows the prefix +
        // bound chords), so they reach this focused overlay. Plain ↩ is handled by the field's `.onSubmit`
        // (TextField-native, reliable); ⌘↩ is NOT a TextField submit, so it reaches THIS container handler —
        // guarding on `.command` (else `.ignored`) keeps the two from double-firing.
        // `OverlayKeyRepeat.phases` (not `.down`): a held arrow WALKS the list, the way every other list on
        // the platform does. `.down` alone moved the selection once per physical press.
        //
        // The full navigation vocabulary follows the platform's list idioms: ↑/↓ step, ⌘↑/⌘↓ jump to the
        // ends (the NSTableView standard), ⇞/⇟ stride one viewport of rows (the VS Code palette page),
        // and ⌃P/⌃N step via the macOS text-system's own previous/next bindings (the emacs pair every
        // terminal user's fingers know). Home/End are deliberately NOT taken — in a focused text field
        // they belong to the query caret, and stealing them would break editing the search text.
        .onKeyPress(.upArrow, phases: OverlayKeyRepeat.phases) { press in
            if press.modifiers.contains(.command) { coordinator.moveSelectionToFirst() }
            else { coordinator.moveSelection(-1) }
            return .handled
        }
        .onKeyPress(.downArrow, phases: OverlayKeyRepeat.phases) { press in
            if press.modifiers.contains(.command) { coordinator.moveSelectionToLast() }
            else { coordinator.moveSelection(1) }
            return .handled
        }
        .onKeyPress(.pageUp, phases: OverlayKeyRepeat.phases) { _ in
            coordinator.moveSelection(-pageStride)
            return .handled
        }
        .onKeyPress(.pageDown, phases: OverlayKeyRepeat.phases) { _ in
            coordinator.moveSelection(pageStride)
            return .handled
        }
        .onKeyPress(keys: ["n", "p"], phases: OverlayKeyRepeat.phases) { press in
            // Only the CONTROL pair navigates — a bare `n`/`p` is query text and must reach the field.
            guard press.modifiers.contains(.control) else { return .ignored }
            coordinator.moveSelection(press.key == "n" ? 1 : -1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            coordinator.acceptSelectedKeepingOpen()
            return .handled
        }
        // Esc for the iPad's hardware keyboard — deliberately NOT ``View/slateCancelKey(perform:)``.
        // That modifier exists to carry the macOS responder-chain half; this card is the phone's
        // (its Mac counterpart is a `MacOverlayPanel`, which takes Esc in AppKit), so the key press
        // IS the handler and there is no second half to carry.
        .onKeyPress(.escape, phases: .down) { _ in
            coordinator.closePalette()
            return .handled
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        // The shared card-top search bar (focus-grab deferral included); plain ↩ runs + closes.
        SlateSearchBar(
            prompt: "Search for commands…",
            text: $coordinator.paletteQuery,
            focus: $searchFocused,
            onSubmit: { coordinator.acceptSelected() },
        )
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayRows) { entry in
                        row(entry.ranked, selectableIndex: entry.selectableIndex)
                    }
                }
                // Rows must not touch the card's own edge — a row clipped flush against the rim reads as
                // a rendering fault rather than as "there is more below".
                .padding(.vertical, Slate.Metric.space2)
            }
            .frame(maxHeight: PaletteMetrics.resultsMaxHeight)
            .onChange(of: coordinator.paletteSelection) { _, _ in
                // Keyboard nav / query-reset only — a HOVER-driven change must not scroll, or the list
                // "follows the mouse" (hover selects → scrollTo slides a new row under the pointer → …).
                guard hoverGate.shouldAutoScrollOnSelectionChange() else { return }
                guard let id = selectedRowID else { return }
                withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func row(_ ranked: RankedRow, selectableIndex: Int?) -> some View {
        if ranked.item.isSeparator {
            sectionHeader(ranked.item)
        } else {
            actionRow(ranked, selectableIndex: selectableIndex ?? 0)
        }
    }

    // MARK: - Section header (+ WORKING DIRECTORY badge)

    private func sectionHeader(_ item: PaletteItem) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            // Mirror the action-row's 20pt leading ✓/icon gutter so the uppercase header text
            // shares the row LABELS' left margin (command-palette.png: the headers are FLUSH with the row
            // labels, the ✓/icon gutter sitting to their LEFT). A section header carries no glyph, so this is an
            // empty placeholder — only its width matters.
            Color.clear.frame(width: 20)
            // The shared caps micro-label — a header reads as the card naming a region rather than as a
            // shouted row (the system face at semibold competed with the row titles under it).
            SlateCapsLabel(item.title)
                // The section label always wins the layout: a long cwd pill truncates its path, never the
                // "WORKING DIRECTORY" header it sits on.
                .layoutPriority(1)
            Spacer(minLength: Slate.Metric.space2)
            // The contextual cwd badge sits flush-right on the WORKING DIRECTORY header it OWNS — matched by
            // the category label, NOT "whichever separator sorts first" (which mislabelled a Recents/Actions
            // header before this section existed).
            if PalettePresentation.headerOwnsWorkingDirectoryBadge(item.title),
               let cwd = PalettePresentation.workingDirectoryBadge(store: store)
            {
                cwdBadge(cwd)
            }
        }
        // `.padding(.horizontal, space3)` is the action-row's INNER padding; `.padding(.leading, space2)` adds
        // its OUTER inset. Together with the 20pt gutter + the `space2` HStack spacing the header text lands at
        // the EXACT x of a row label (space2 + space3 + 20 + space2), so headers + labels are flush (the row's
        // inset highlight + ✓-gutter are left untouched). The trailing `space2` mirrors the action
        // row's OUTER inset (space3 + space2 = 20pt) so the cwd pill's RIGHT edge lines up with the keycap-chip
        // column instead of jutting `space2` past it (command-palette.png: pill + keycaps share one right edge).
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.leading, Slate.Metric.space2)
        .padding(.trailing, Slate.Metric.space2)
        .padding(.top, Slate.Metric.space3)
        .padding(.bottom, Slate.Metric.space1)
        .id(item.id)
    }

    private func cwdBadge(_ cwd: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .folder)
                .font(.system(size: Slate.Typeface.small))
            Text(cwd)
                .font(.system(size: Slate.Typeface.small))
                .lineLimit(1)
                // Head-truncate so the leaf (the directory you're actually in) stays visible when the pill
                // shrinks — default `.tail` would drop the most meaningful part of the path.
                .truncationMode(.head)
        }
        .foregroundStyle(SlateOverlayInk.secondary)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(SlateOverlayInk.plate),
        )
    }

    // MARK: - Action row

    private func actionRow(_ ranked: RankedRow, selectableIndex: Int) -> some View {
        let item = ranked.item
        let isSelected = selectableIndex == coordinator.paletteSelection
        return HStack(spacing: Slate.Metric.space2) {
            // Leading 24pt gutter: the ✓ toggled-state checkmark, or empty. Set in the reading ink, not an
            // accent — a checkmark already means one thing, and colouring it says nothing more.
            ZStack {
                if toggledState(item) {
                    Image(systemSymbol: .checkmark)
                        .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                        .foregroundStyle(SlateOverlayInk.primary)
                }
            }
            .frame(width: 20, alignment: .center)

            // The selected row's title goes HEAVIER, never coloured — the card vocabulary's rule that
            // importance is light and weight, not hue.
            highlightedTitle(ranked)
                .font(.system(size: Slate.Typeface.body, weight: isSelected ? .medium : .regular))
                .lineLimit(1)

            // The subtitle (a PANES row's place line / app name — verbs carry none) rides beside the
            // title in the secondary ink: identically-titled panes are told apart by where they live.
            // Head-truncated so a squeezed path keeps its leaf (the directory that identifies the pane).
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text.nerdAware(subtitle, size: Slate.Typeface.small)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(SlateOverlayInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Slate.Metric.space2)

            // ONE cap for the whole chord ("⇧⌘L"), not a cap per glyph: the modifiers are not separate
            // keys to hunt for, they are one gesture, and a row of little boxes read as four things to do.
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                SlateKeycap(label: shortcut, lit: isSelected)
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRowTall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateSelectionPlate(isSelected)
        .padding(.horizontal, Slate.Metric.space2)
        .contentShape(Rectangle())
        // The click is the row itself (a button WRAPPED around it, never one laid over it — an overlaid
        // target is topmost for the pointer and eats the hover below).
        .slateRowButton { coordinator.run(item) }
        // Hover moves the keyboard selection onto this row (spec: hover/tap → run) — but only on genuine
        // pointer MOVEMENT (`.global`-space location changed): a keyboard scrollTo sliding this row under a
        // parked pointer re-fires hover too, and admitting that would yank the selection back to the mouse.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case let .active(location) = phase, hoverGate.admitHover(at: location) else { return }
            guard coordinator.paletteSelection != selectableIndex else { return }
            hoverGate.noteHoverDrivenSelection()
            coordinator.paletteSelection = selectableIndex
        }
        .id(item.id)
    }

    // MARK: - Title highlight (fzf ranges)

    /// The row title as a `Text`, with the fzf-matched code-point runs (``RankedRow/titleRanges``) marked. A
    /// range-less row (separator / zero-state / subtitle-only match) renders flat.
    ///
    /// The mark is CONTRAST, not colour: the matched run keeps the reading ink at semibold while the letters
    /// around it step back to `secondary`, so what the query hit reads as lit rather than as tinted. It was
    /// the system accent, which put the one blue thing on an otherwise monochrome card (and the one PINK
    /// thing on a machine whose accent is pink).
    private func highlightedTitle(_ ranked: RankedRow) -> Text {
        let title = ranked.item.title
        // Every run goes through `nerdAware` so a PANES row's private-use glyph (an agent/program
        // title's nerd-font mark) draws from the bundled symbols face inside the highlight run too.
        // WHERE the cuts fall is ``FuzzyMatcher/runs(of:ranges:)``'s, shared with the Mac's palette row
        // and with both halves of Open Quickly; the ink is this half's.
        let runs = FuzzyMatcher.runs(of: title, ranges: ranked.titleRanges)
        guard runs.count > 1 else {
            return Text.nerdAware(title, size: Slate.Typeface.body).foregroundStyle(SlateOverlayInk.primary)
        }
        // The segments are spliced into one run (`Text.spliced` — the interpolation fold that replaced
        // the deprecated `Text + Text`).
        return .spliced(runs.map { run in
            Text.nerdAware(run.text, size: Slate.Typeface.body)
                .foregroundStyle(run.matched ? SlateOverlayInk.primary : SlateOverlayInk.secondary)
                .fontWeight(run.matched ? .semibold : .regular)
        })
    }

    // MARK: - Derived data

    /// The result rows paired with their selectable index — separators carry `nil`.
    private var displayRows: [PaletteDisplayRow] {
        PalettePresentation.displayRows(coordinator.rankedResults)
    }

    /// The id of the currently keyboard-selected row (for `scrollTo`), or nil if nothing is selectable.
    private var selectedRowID: String? {
        PalettePresentation.selectedRowID(coordinator.rankedResults, selection: coordinator.paletteSelection)
    }
}

#endif
