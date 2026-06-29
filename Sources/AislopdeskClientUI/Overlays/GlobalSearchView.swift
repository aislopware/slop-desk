// GlobalSearchView — the cross-tab Global Search results surface (E5 / WI-4), opened by ⇧⌘F. A LARGE,
// content-area-filling, NON-scrimmed card (E5 divergence #1: the closest faithful equivalent to otty's
// dedicated results *tab*, which we do not add to avoid blast-radius across every `switch PaneKind` site).
// Mounted by ``OverlayHostView`` over the workspace WITHOUT a ``Scrim`` so it does not dim the panes.
//
// Anatomy matches `screenshots/global-search.png` (`Otty.*` tokens ONLY — raw font / colour / radius literals
// fail `scripts/check-ds-leaks.sh`):
//   ┌ query field [ Aa ][ .* ] ────────────────────────────────────────┐
//   │ N results — M tabs                                               │
//   │ ▸ <terminal-glyph> <group title (tab)>                           │
//   │     <excerpt with the matched run highlighted amber>      →      │  (→ on the HOVERED row only)
//   │ ▸ <group title> …                                                │
//   └──────────────────────────────────────────────────────────────────┘
// (No leading magnifier on the query bar — the field is flush-left per global-search.png — and no in-bar `×`:
// the surface is dismissed via Esc. The ⌘1/⌘2/⌘3 numbers in the screenshot are SIDEBAR tab numbers, NOT group
// headers, so the group header carries only a leading terminal glyph + the tab title.)
//
// SEAM discipline: this view owns ONLY its transient field/toggle `@State` (mirroring the store's retained
// `globalSearchQuery`/flags so a re-open restores them); ALL match math runs in the store via the PURE
// ``GlobalSearchController`` (``WorkspaceStore/runGlobalSearch``) — never a second matcher. A row tap jumps via
// ``WorkspaceStore/jumpToGlobalSearchResult(_:)`` then closes through the coordinator. The amber highlight is
// the in-buffer `GlobalSearchHit.highlight` UTF-16 range tinted on the excerpt (divergence #2: the counter /
// excerpt come from the scrollback mirror; the live in-pane highlight is libghostty's on jump).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct GlobalSearchView: View {
    /// The live store — owns the results (``WorkspaceStore/globalSearch``) + the run/jump ops. Read in `body`
    /// (`store.globalSearch`), so the `@Observable` store re-renders this view as results land.
    let store: WorkspaceStore
    /// The single overlay reducer — closes this surface on Esc / row tap / × via ``OverlayCoordinator/closeGlobalSearch()``.
    /// Only its methods are called here (no two-way binding), so a plain `let` reference suffices.
    let coordinator: OverlayCoordinator

    /// The transient query field — mirrors ``WorkspaceStore/globalSearchQuery`` (restored on appear) and writes
    /// back through ``WorkspaceStore/runGlobalSearch`` on every keystroke (live re-run, ES-E5-5).
    @State private var query = ""
    /// `Aa` / `.*` mirrors of the store's retained flags (restored on appear; a toggle re-runs).
    @State private var caseSensitive = false
    @State private var isRegex = false

    /// Per-group collapse state (E5: `user-interface__find.md` — each tab group is a COLLAPSIBLE group with a
    /// leading disclosure control). Keyed by ``PaneID`` so a live re-run that re-orders/drops groups carries
    /// the collapse intent to surviving panes and lets a vanished pane's id fall away. Default = all expanded.
    @State private var collapse = GlobalSearchCollapseState()

    /// Pre-focuses the query field on appear so typing reaches it immediately (otty parity).
    @FocusState private var queryFocused: Bool

    // Platform mode-pill plate size — MUST match ``TerminalFindBar``'s `plate` exactly (34 on iOS for the touch
    // target, `Otty.Metric.plate` on macOS) so the locked invariant "the find bar and the global-search query
    // bar render the pills IDENTICALLY" holds on BOTH platforms. Threaded into each ``FindTogglePill`` below.
    #if os(iOS)
    private let plate: CGFloat = 34
    #else
    private let plate: CGFloat = Otty.Metric.plate
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            queryBar
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            summaryLine
            resultsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Otty.Surface.window)
        .onAppear { restoreFromStore() }
        #if os(macOS)
            .onExitCommand { coordinator.closeGlobalSearch() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                coordinator.closeGlobalSearch()
                return .handled
            }
        #endif
    }

    // MARK: - Query bar

    private var queryBar: some View {
        // No leading magnifier — the query text is flush-left per global-search.png. No in-bar `×` either: the
        // overlay's dismiss affordance is Esc (`onExitCommand` / `.onKeyPress(.escape)` on the surface).
        HStack(spacing: Otty.Metric.space2) {
            TextField("Search across all tabs…", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
                .focused($queryFocused)
                // The query text sits inside a FILLED, hairline-bordered rounded plate (global-search.png): the
                // same `Surface.card` fill + `radiusSmall` as `TerminalFindBar.queryField`, but PLUS its own
                // `Line.subtle` hairline. That extra ring is INTENTIONALLY context-different, NOT an asymmetry to
                // "fix": this overlay's field sits on bare `Surface.window`, so it needs its own border to read as a
                // field plate; the find bar's field sits inside an already `Line.subtle`-bordered `Surface.element`
                // card (TerminalFindBar.swift:227-230), so a second ring there would double the border and risk
                // find.png fidelity. Do NOT add a border to `queryField` to "match" this. Both readings are
                // screenshot-faithful. The `Aa` / `.*` pills stay OUTSIDE this plate (siblings in the HStack).
                .padding(.horizontal, Otty.Metric.space2)
                .padding(.vertical, Otty.Metric.space1)
                .background(Otty.Surface.card, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                        .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
                )
            // The mode pills render as INDIVIDUALLY-OUTLINED chips (each its own resting plate + hairline,
            // gaps between — NO shared backing tray) per global-search.png. ``FindTogglePillTray`` is the EXACT
            // layout container the find bar reuses, so the two surfaces render the pills identically.
            FindTogglePillTray {
                FindTogglePill(label: "Aa", isOn: caseSensitive, help: "Case sensitive", plate: plate) {
                    caseSensitive.toggle()
                    rerun()
                }
                FindTogglePill(label: ".*", isOn: isRegex, help: "Regex (ICU)", plate: plate) {
                    isRegex.toggle()
                    rerun()
                }
            }
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
    }

    // MARK: - Summary line (`N results — M tabs`)

    @ViewBuilder private var summaryLine: some View {
        if let results = store.globalSearch, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(results.summary)
                .font(.system(size: Otty.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space4)
                .padding(.vertical, Otty.Metric.space2)
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let groups = store.globalSearch?.groups ?? []
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        groupHeader(group)
                        if collapse.showsHits(group.paneID) {
                            ForEach(Array(group.hits.enumerated()), id: \.offset) { _, hit in
                                GlobalSearchHitRow(excerpt: highlightedExcerpt(hit)) { jump(to: hit) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Otty.Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The blank / no-match state: a hint when the query is empty, a "no results" line when it matched nothing.
    private var emptyState: some View {
        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Search every tab’s scrollback."
            : "No results.")
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Otty.Metric.space4)
    }

    // MARK: - Group header (one per tab/pane)

    private func groupHeader(_ group: GlobalSearchGroup) -> some View {
        // Per `user-interface__find.md`:134-136 each tab group is COLLAPSIBLE via a leading disclosure control
        // ("checkbox-style expand/collapse control to the left of the tab/file name header") — the `▸`/`▾`
        // chevron below — followed by global-search.png's per-tab terminal glyph + the tab title. The whole
        // header row toggles the group (otty disclosure-row idiom). (No ⌘ordinal badge: the ⌘1/⌘2/⌘3 numbers
        // in the screenshot are SIDEBAR tab numbers, not group headers.)
        let collapsed = collapse.isCollapsed(group.paneID)
        return HStack(spacing: Otty.Metric.space2) {
            // The disclosure control: a right-chevron when collapsed, a down-chevron when expanded — the
            // checkbox-style expand/collapse affordance the spec puts to the LEFT of the header. Sized to the
            // footnote metric so it sits flush with the terminal glyph + title on the same baseline.
            Image(systemSymbol: collapsed ? .chevronRight : .chevronDown)
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.Text.secondary)
                .frame(width: Otty.Typeface.body, alignment: .center)
            // `.appleTerminal` (rawValue "apple.terminal") renders the `>_` PROMPT-BOX terminal glyph that
            // global-search.png shows — it is NOT an Apple-logo mark (verified by rendering the symbol). It is
            // the CURRENT, non-deprecated name; the bare `.terminal` case is the SAME glyph under its old name,
            // deprecated/renamed to `.appleTerminal` in macOS 14 — so we use `.appleTerminal` to stay
            // warning-clean (`.terminal` trips a deprecation warning for an identical pixel result). Locked: a
            // future "this is Apple-branded, switch to `.terminal`" flag is already-resolved — both are the `>_`
            // box; `.appleTerminal` is the non-deprecated spelling.
            Image(systemSymbol: .appleTerminal)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            Text(group.groupTitle)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            Spacer(minLength: Otty.Metric.space2)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .padding(.top, Otty.Metric.space3)
        .padding(.bottom, Otty.Metric.space1)
        .contentShape(Rectangle())
        .onTapGesture { collapse.toggle(group.paneID) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(group.groupTitle))
        .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
    }

    // MARK: - Hit row (extracted so each row owns its own hover @State for the hover-reveal jump glyph)

    /// The excerpt (the full matched line) as an `AttributedString` with the matched run tinted amber + primary
    /// (the otty find highlight) and the rest muted. The hit's `highlight` is a UTF-16 column range pre-clamped
    /// into the excerpt by ``GlobalSearchController``; map it back onto the string and SLICE the excerpt into
    /// before / match / after so a surrogate-straddling range degrades to a flat excerpt rather than indexing
    /// out of bounds. Built by substring concatenation (no AttributedString index conversion) so it can't trap.
    private func highlightedExcerpt(_ hit: GlobalSearchHit) -> AttributedString {
        let excerpt = hit.excerpt
        let utf16 = excerpt.utf16
        guard let lowUTF16 = utf16
            .index(utf16.startIndex, offsetBy: hit.highlight.lowerBound, limitedBy: utf16.endIndex),
            let highUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: hit.highlight.upperBound,
                limitedBy: utf16.endIndex,
            ),
            let low = lowUTF16.samePosition(in: excerpt),
            let high = highUTF16.samePosition(in: excerpt),
            low <= high
        else {
            var flat = AttributedString(excerpt)
            flat.foregroundColor = Otty.Text.secondary
            return flat
        }
        var before = AttributedString(String(excerpt[excerpt.startIndex..<low]))
        before.foregroundColor = Otty.Text.secondary
        var match = AttributedString(String(excerpt[low..<high]))
        match.foregroundColor = Otty.Text.primary
        match.backgroundColor = Otty.Status.warn.opacity(0.35)
        var after = AttributedString(String(excerpt[high...]))
        after.foregroundColor = Otty.Text.secondary
        return before + match + after
    }

    // MARK: - Actions

    /// Two-way binding into the query field — read the live `@State`, write it through `runGlobalSearch` so each
    /// keystroke re-runs the cross-tab search (live results, ES-E5-5).
    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { query = $0
            rerun()
        })
    }

    private func rerun() {
        store.runGlobalSearch(query: query, caseSensitive: caseSensitive, isRegex: isRegex)
    }

    /// Restore the field + pills from the store's retained query/flags so a ⇧⌘F re-open shows the last search
    /// (E5 divergence #1). Does NOT re-run on its own — the store already holds the last results to display.
    private func restoreFromStore() {
        query = store.globalSearchQuery
        caseSensitive = store.globalSearchCaseSensitive
        isRegex = store.globalSearchRegex
        // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
        // dropped — defer one runloop hop (the palette / find-bar idiom).
        DispatchQueue.main.async { queryFocused = true }
    }

    private func jump(to hit: GlobalSearchHit) {
        store.jumpToGlobalSearchResult(hit)
        coordinator.closeGlobalSearch()
    }
}

/// One result row: the highlighted excerpt + a trailing rightward-arrow (→) jump glyph that is HOVER-REVEALED
/// — per `global-search.png` the → appears only on the hovered row, not unconditionally. Extracted to file
/// scope so each row owns its own `@State hovering` (a parent-level hovered-index would need globally-unique
/// ids across groups). The tap jumps via the injected closure (the parent owns the store/coordinator hop).
private struct GlobalSearchHitRow: View {
    let excerpt: AttributedString
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(excerpt)
                .font(.system(size: Otty.Typeface.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Otty.Metric.space2)
            // Horizontal → (global-search.png), hover-revealed: visible only on the row under the pointer.
            Image(systemSymbol: .arrowRight)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onJump() }
    }
}
#endif
