// GlobalSearchView — the PHONE's cross-tab Global Search results surface, opened by ⇧⌘F. A LARGE,
// content-area-filling, NON-scrimmed card (a dedicated results *overlay* rather than a
// results *tab*, which we do not add to avoid blast-radius across every `switch PaneKind` site).
// Presented as a NATIVE `.sheet` by ``OverlayHostView`` — a large results window on macOS (system chrome).
//
// Anatomy matches `screenshots/global-search.png` (`Slate.*` tokens ONLY — raw font / colour / radius literals
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
// the in-buffer `GlobalSearchHit.highlight` UTF-16 range tinted on the excerpt (the counter /
// excerpt come from the scrollback mirror; the live in-pane highlight is libghostty's on jump).
//
// ⚠️ THE PHONE's, since docs/56 stage D: the Mac draws this panel in AppKit
// (``SlopDeskMacUI/MacGlobalSearchView``) and has dropped `.globalSearch` from ``OverlayHostView``'s
// `draws` set, so on macOS this body is never mounted. Nothing here may spell what the surface SAYS
// or how it CUTS a hit apart — the two zero-state lines, the mode pills' glyphs and help, the
// panel's own dimensions, and the before/match/after slicing of an excerpt are all
// ``GlobalSearchPresentation``'s / ``FindModePill``'s / ``GlobalSearchMetrics``'s, and
// `check-supervisor.sh` fails the build if either half re-derives one. The excerpt slicing matters
// most: a UTF-16 range that lands inside a surrogate pair has no `String.Index`, and a half that
// re-wrote that guard would eventually trap on the one scrollback line containing an emoji.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

struct GlobalSearchView: View {
    /// The live store — owns the results (``WorkspaceStore/globalSearch``) + the run/jump ops. Read in `body`
    /// (`store.globalSearch`), so the `@Observable` store re-renders this view as results land.
    let store: WorkspaceStore
    /// The single overlay reducer — closes this surface on Esc / row tap / × via ``OverlayCoordinator/closeGlobalSearch()``.
    /// Only its methods are called here (no two-way binding), so a plain `let` reference suffices.
    let coordinator: OverlayCoordinator

    /// The transient query field — mirrors ``WorkspaceStore/globalSearchQuery`` (restored on appear) and writes
    /// back through ``WorkspaceStore/runGlobalSearch`` on every keystroke (live re-run).
    @State private var query = ""
    /// `Aa` / `.*` mirrors of the store's retained flags (restored on appear; a toggle re-runs).
    @State private var caseSensitive = false
    @State private var isRegex = false

    /// Per-group collapse state (`user-interface__find.md` — each tab group is a COLLAPSIBLE group with a
    /// leading disclosure control). Keyed by ``PaneID`` so a live re-run that re-orders/drops groups carries
    /// the collapse intent to surviving panes and lets a vanished pane's id fall away. Default = all expanded.
    @State private var collapse = GlobalSearchCollapseState()

    /// Pre-focuses the query field on appear so typing reaches it immediately.
    @FocusState private var queryFocused: Bool

    // Platform mode-pill plate size — MUST match ``TerminalFindBar``'s `plate` exactly (34 on iOS for the touch
    // target, `Slate.Metric.plate` on macOS) so the locked invariant "the find bar and the global-search query
    // bar render the pills IDENTICALLY" holds. Threaded into each ``FindTogglePill`` below.
    #if os(iOS)
    private let plate: CGFloat = 34
    #else
    private let plate: CGFloat = Slate.Metric.plate
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            queryBar
            // The card's one internal line, and it is earned: results scroll UNDER the query field.
            SlateCardSeparator()
            summaryLine
            resultsList
        }
        // Presented as a native `.sheet` by `OverlayHostView` — a large results window on macOS (the system
        // provides the window chrome), full-sheet on iOS.
        #if os(macOS)
        .frame(
            width: GlobalSearchMetrics.panelWidth,
            height: GlobalSearchMetrics.panelHeight,
            alignment: .topLeading,
        )
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
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
        HStack(spacing: Slate.Metric.space2) {
            TextField("Search across all tabs…", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(SlateOverlayInk.primary)
                .tint(SlateOverlayInk.primary) // the caret is the text's own ink, not an accent
                .focused($queryFocused)
                // The query sinks into the shared field plate (``View/slateFieldPlate()``) — the same recipe
                // the connect card's inputs take, so an editable field looks the same on every overlay. The
                // find bar's sibling field (`TerminalFindBar.queryField`) keeps a `State.selected` fill
                // instead: it sits on the elevated, borderless `Surface.raised` card, whose wash inverts
                // contrast by theme, so its ring has to delineate in the other direction. Both are
                // hairline-delineated; only the fill is context-specific. The `Aa` / `.*` pills stay OUTSIDE
                // this plate (siblings in the HStack).
                .slateFieldPlate()
            // The mode pills render as INDIVIDUALLY-OUTLINED chips (each its own resting plate + hairline,
            // gaps between — NO shared backing tray) per global-search.png. ``FindTogglePillTray`` is the EXACT
            // layout container the find bar reuses, so the two surfaces render the pills identically.
            // WHICH pills, and in what order, is ``FindModePill/globalSearch``'s — the cross-tab
            // search offers two of the find bar's three (no whole-word: it runs over the scrollback
            // mirror, which does not agree with libghostty's buffer about a word boundary).
            FindTogglePillTray {
                ForEach(FindModePill.globalSearch, id: \.self) { mode in
                    FindTogglePill(mode: mode, isOn: isOn(mode), plate: plate) { toggle(mode) }
                }
            }
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: Slate.Metric.heightInput)
    }

    // MARK: - Summary line (`N results — M tabs`)

    @ViewBuilder private var summaryLine: some View {
        if let summary = GlobalSearchPresentation.summary(store.globalSearch, query: query) {
            Text(summary)
                .font(.system(size: Slate.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(SlateOverlayInk.secondary)
                .padding(.horizontal, Slate.Metric.space4)
                .padding(.vertical, Slate.Metric.space2)
                // Same numeric roll as the in-pane find counter: live re-runs tick the counts to their new
                // values rather than teleporting the line (the two search counters must read identically).
                .contentTransition(.numericText())
                .animation(Slate.Anim.smallFade, value: summary)
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
            .padding(.vertical, Slate.Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The blank / no-match state: a hint when the query is empty, a "no results" line when it matched nothing.
    private var emptyState: some View {
        SlateNoResultsLine(
            message: GlobalSearchPresentation.emptyStateLine(query: query),
            ink: SlateOverlayInk.tertiary,
        )
    }

    // MARK: - Group header (one per tab/pane)

    private func groupHeader(_ group: GlobalSearchGroup) -> some View {
        // Per `user-interface__find.md`:134-136 each tab group is COLLAPSIBLE via a leading disclosure control
        // ("checkbox-style expand/collapse control to the left of the tab/file name header") — the `▸`/`▾`
        // chevron below — followed by global-search.png's per-tab terminal glyph + the tab title. The whole
        // header row toggles the group (a disclosure-row idiom). (No ⌘ordinal badge: the ⌘1/⌘2/⌘3 numbers
        // in the screenshot are SIDEBAR tab numbers, not group headers.)
        let collapsed = collapse.isCollapsed(group.paneID)
        return HStack(spacing: Slate.Metric.space2) {
            // The disclosure control: a right-chevron when collapsed, a down-chevron when expanded — the
            // checkbox-style expand/collapse affordance the spec puts to the LEFT of the header. Sized to the
            // footnote metric so it sits flush with the terminal glyph + title on the same baseline.
            Image(systemSymbol: collapsed ? .chevronRight : .chevronDown)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(SlateOverlayInk.secondary)
                .frame(width: Slate.Typeface.body, alignment: .center)
            // `.appleTerminal` (rawValue "apple.terminal") renders the `>_` PROMPT-BOX terminal glyph that
            // global-search.png shows — it is NOT an Apple-logo mark (verified by rendering the symbol). It is
            // the CURRENT, non-deprecated name; the bare `.terminal` case is the SAME glyph under its old name,
            // deprecated/renamed to `.appleTerminal` in macOS 14 — so we use `.appleTerminal` to stay
            // warning-clean (`.terminal` trips a deprecation warning for an identical pixel result). Locked: a
            // future "this is Apple-branded, switch to `.terminal`" flag is already-resolved — both are the `>_`
            // box; `.appleTerminal` is the non-deprecated spelling.
            Image(systemSymbol: .appleTerminal)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(SlateOverlayInk.secondary)
            Text(group.groupTitle)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(SlateOverlayInk.secondary)
                .lineLimit(1)
            Spacer(minLength: Slate.Metric.space2)
        }
        .padding(.horizontal, Slate.Metric.space4)
        .padding(.top, Slate.Metric.space3)
        .padding(.bottom, Slate.Metric.space1)
        .contentShape(Rectangle())
        .slateRowButton { collapse.toggle(group.paneID) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(group.groupTitle))
        .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
    }

    // MARK: - Hit row (extracted so each row owns its own hover @State for the hover-reveal jump glyph)

    /// The excerpt (the full matched line) as an `AttributedString`: the matched run tinted amber +
    /// primary (the find highlight), the rest muted.
    ///
    /// WHERE the cut falls is ``GlobalSearchPresentation/excerptSlices(_:)``'s — including the case where
    /// it cannot fall anywhere, which comes back as the whole line in `before` and needs no flag here: the
    /// two outer runs take the supporting ink and the middle one is marked, so an empty middle simply marks
    /// nothing. What is left here is only the INK, which is a SwiftUI answer the AppKit half spells in
    /// `NSAttributedString` from the same three strings.
    private func highlightedExcerpt(_ hit: GlobalSearchHit) -> AttributedString {
        let slices = GlobalSearchPresentation.excerptSlices(hit)
        var before = AttributedString(slices.before)
        before.foregroundColor = SlateOverlayInk.secondary
        var match = AttributedString(slices.match)
        match.foregroundColor = SlateOverlayInk.primary
        match.backgroundColor = Slate.Status.warn.opacity(0.35)
        var after = AttributedString(slices.after)
        after.foregroundColor = SlateOverlayInk.secondary
        return before + match + after
    }

    // MARK: - Actions

    /// Two-way binding into the query field — read the live `@State`, write it through `runGlobalSearch` so each
    /// keystroke re-runs the cross-tab search (live results).
    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { query = $0
            rerun()
        })
    }

    private func rerun() {
        store.runGlobalSearch(query: query, caseSensitive: caseSensitive, isRegex: isRegex)
    }

    /// Whether `mode`'s chip is lit. `.wholeWord` can never reach here — it is not in
    /// ``FindModePill/globalSearch`` — and reads `false` rather than crashing if it ever does.
    private func isOn(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: caseSensitive
        case .regex: isRegex
        case .wholeWord: false
        }
    }

    private func toggle(_ mode: FindModePill) {
        switch mode {
        case .caseSensitive: caseSensitive.toggle()
        case .regex: isRegex.toggle()
        case .wholeWord: return
        }
        rerun()
    }

    /// Restore the field + pills from the store's retained query/flags so a ⇧⌘F re-open shows the last search.
    /// Does NOT re-run on its own — the store already holds the last results to display.
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
        HStack(spacing: Slate.Metric.space2) {
            Text(excerpt)
                .font(.system(size: Slate.Typeface.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Slate.Metric.space2)
            // Horizontal → (global-search.png), hover-revealed: visible only on the row under the pointer.
            Image(systemSymbol: .arrowRight)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(SlateOverlayInk.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover lifts the row onto the shared selection plate — the same plate a keyboard-selected palette
        // row takes, because on this surface the pointer IS the selection (there is no keyboard cursor).
        .slateSelectionPlate(hovering)
        .padding(.horizontal, Slate.Metric.space3)
        .contentShape(Rectangle())
        // WRAPPED, not overlaid: a click target laid over the row is topmost for the pointer, so it eats
        // the `.onHover` beneath it — and on this surface hover IS the selection.
        .slateRowButton(onJump)
        .onHover { hovering = $0 }
    }
}
#endif
