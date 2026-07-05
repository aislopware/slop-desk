// TerminalFindBar — the in-pane ⌘F find overlay (E5 / WI-3). A THIN SwiftUI driver over the PURE
// ``TerminalSearchController`` (the single source of truth for count / N-of-M / next-prev-wrap) plus
// libghostty's OWN in-surface search bindings (`search:` / `navigate_search:` / `end_search`, via
// ``TerminalViewModel/performSearchSurfaceAction(_:)``), which own the amber highlight + scroll-to-match.
// The counter counts the `scrollbackTextLines()` snapshot taken on open (divergence #2 in plans/E5.md):
// count is the mirror's, highlight is libghostty's — they agree on the same buffer; the mirror refreshes
// on open + on the `Aa` / `.*` toggles.
//
// REGEX-MODE CEILING (ES-E5-4 honesty fix). libghostty's in-surface search is a LITERAL substring matcher with
// NO regex engine (`changeNeedle` compares case-insensitively; no pattern compilation). So in `.*` mode we must
// NOT arm `search:<pattern>` — it would highlight the literal pattern text (usually 0 hits) while the counter
// reports the real regex count, and `navigate_search:` would move nothing (a lying counter beside dead
// chevrons / ⌘G). Instead regex mode is driven ENTIRELY from the controller's match positions: `end_search`
// (clears any stale highlight) + `scroll_to_row:<Match.line>` on open / next / previous so the viewport scrolls
// to each match (chevrons / ⌘G / ⇧⌘G stay live). `Match.line` is the 0-based row into the same
// `scrollbackTextLines()` mirror the controller scanned — the row `scroll_to_row:<usize>` addresses. Regex mode
// CANNOT have the amber per-glyph highlight (libghostty can't render regex spans): that is the documented
// ceiling; counter + nav stay correct. Corollary: when several matches share one already-visible row,
// next/previous re-issue the IDENTICAL `scroll_to_row:<row>` — the "k of N" counter advances with no viewport
// change (matches already on-screen, no per-span highlight to move). Expected, not a stall. Literal mode is
// unchanged: `search:` + `navigate_search:next`/`previous`.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Slate.*` tokens ONLY — raw
// font / radius literals fail `scripts/check-ds-leaks.sh`):
//   [ query field ][ Aa case pill ][ ab whole-word pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ]
//   [ ▣ search-all-tabs ][ × close ]
// (`rectangle.stack` "search all tabs" escalates to cross-tab Global Search ⇧⌘F — see
// ``TerminalFindBarModel/searchAllTabs()``.)
// (ES-E5-2 requires the `N of M` counter; `find.png` shows no inline counter, so its placement isn't
// screenshot-driven — we keep it before the nav chevrons.)
//
// Behaviour (ES-E5-1..4): auto-focus the field on appear; live query → recompute + re-arm highlight;
// ↩ / ⇧↩ next / prev; `Aa` / `.*` toggle case / regex; Esc (or ×) closes + clears highlights. The bar OWNS
// no match math — `TerminalFindBarModel` wraps the controller + a weak model ref so the GUI and the headless
// unit test (`TerminalFindBarModelTests`) drive the exact same logic.
//
// Hang-safety: NO `GhosttySurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// The find bar's view-model: the PURE ``TerminalSearchController`` (count / nav) + a weak pane
/// ``TerminalViewModel`` ref (scrollback mirror + libghostty `search:` passthrough). `@Observable` so the bar
/// re-renders on every query / toggle / nav; held as `@State` by ``TerminalLeafView``, wired to the pane's
/// `onRequestFind` / `onRequestFindNext` / `onRequestFindPrev`. Weak model ref so a torn-down pane isn't kept
/// alive by the bar (the leaf is `.id(PaneID)`-keyed — an identity hazard).
@MainActor
@Observable
final class TerminalFindBarModel {
    /// Whether the bar is shown over its pane (the leaf's top-trailing overlay gate).
    var visible = false
    /// The PURE match engine — the single source of truth for the counter + nav. `private(set)`: only the
    /// model's own methods mutate it (each mutation notifies `@Observable`, so the bar re-renders).
    private(set) var controller = TerminalSearchController()
    /// Bumped on every (re)open so the view re-asserts its `@FocusState` even when the bar is already mounted
    /// (⌘F while the bar is open should re-focus the field, but `.onAppear` won't fire again).
    private(set) var focusToken = 0
    /// The SEARCH DIRECTION the bar opened in (E17 ES-E17-2 / WI-5): `/` and ⌘F search FORWARD (`false`); a
    /// copy-mode `?` opens BACKWARD (`true`, via ``open(backward:)``). Biases vi's `n`/`N`: ``next()`` (`n`)
    /// steps in this direction, ``previous()`` (`N`) against it — so after `?foo`, `n` walks UP and `N` down
    /// (vim parity); a forward search keeps the natural sense.
    private(set) var searchBackward = false
    /// The pane's terminal model — the scrollback mirror + the libghostty `search:` / `navigate_search:` /
    /// `end_search` passthrough. Weak (owned by the live session); `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private weak var model: TerminalViewModel?

    /// E5 "search all tabs" escalation — the `rectangle.stack` button (`find.png`). Opens cross-tab Global
    /// Search (⇧⌘F) seeded with the live query. Wired by ``TerminalLeafView`` to
    /// ``OverlayCoordinator/openGlobalSearch(seed:)``; `nil` in previews / tests ⇒ the button still dismisses
    /// the bar but the escalation no-ops. Pure wiring, so `@ObservationIgnored`.
    @ObservationIgnored var onSearchAllTabs: ((String) -> Void)?

    init() {}

    /// Bind (or unbind, with `nil`) the pane's terminal model. ``TerminalLeafView`` calls this when it wires /
    /// clears the `onRequestFind*` callbacks (per-pane, so a torn-down leaf can't drive a dead model).
    func attach(_ model: TerminalViewModel?) { self.model = model }

    /// ⌘F / Find… — open (or re-focus) the bar, refreshing the scrollback mirror snapshot the counter counts
    /// (divergence #2: libghostty owns the live highlight, this snapshot owns the `N of M` count). `backward`
    /// seeds the SEARCH DIRECTION (default forward; a copy-mode `?` passes `true`) so `n`/`N` step relative to
    /// it — see ``searchBackward`` / ``next()`` / ``previous()``.
    func open(backward: Bool = false) {
        searchBackward = backward
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
        visible = true
        focusToken &+= 1
    }

    /// Live query edit — recompute matches (counter) + re-arm libghostty's in-surface highlight.
    func setQuery(_ text: String) {
        controller.setQuery(text)
        armSearch()
    }

    /// `Aa` — flip case sensitivity, refresh the mirror (divergence #2), recompute + re-arm.
    func toggleCaseSensitive() {
        controller.setCaseSensitive(!controller.caseSensitive)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// `.*` — flip regex mode (ICU `NSRegularExpression`), refresh the mirror, recompute + re-arm.
    func toggleRegex() {
        controller.setRegex(!controller.isRegex)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// `ab` (underlined) — flip whole-word matching, refresh the mirror, recompute + re-arm. Like regex,
    /// libghostty's LITERAL search can't express this (no word-boundary filter), so the bar drives nav from its
    /// own match rows via `scroll_to_row` rather than arming `search:` — else libghostty would highlight (and
    /// `navigate_search:` step through) every substring, diverging from the whole-word counter. See
    /// ``needsRowDrivenNav`` / the header's REGEX-MODE CEILING note.
    func toggleWholeWord() {
        controller.setWholeWord(!controller.wholeWord)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// Whether the controller's current mode CANNOT be expressed FAITHFULLY by libghostty's literal search, so
    /// the bar must drive nav from its OWN match rows via `scroll_to_row:` instead of `search:` /
    /// `navigate_search:`. True for regex (no regex engine), whole-word (no word-boundary filter), AND
    /// case-SENSITIVE (libghostty's matcher is HARD-WIRED case-insensitive — `std.ascii.indexOfIgnoreCase`).
    /// Arming `search:` in case-sensitive mode would highlight (and `navigate_search:` would step) extra
    /// case-folded hits the case-sensitive counter says don't exist — counter, highlight, and chevrons would
    /// permanently disagree. Mirrors ``GlobalSearchController``'s click-to-line fix, which already routes
    /// case-sensitive jumps through `end_search` + `scroll_to_row`.
    private var needsRowDrivenNav: Bool { controller.isRegex || controller.wholeWord || controller.caseSensitive }

    /// ↩ / ⌘G / vi `n` — step to the next match IN THE SEARCH DIRECTION + move the live grid to it. Opens the
    /// bar first if closed, preserving direction. Forward search advances (down); a `?`-opened backward search
    /// retreats (up) — vim's "`n` repeats in its original direction".
    func next() {
        if !visible { open(backward: searchBackward) }
        step(forward: !searchBackward)
    }

    /// ⇧↩ / ⇧⌘G / vi `N` — step to the next match AGAINST the search direction + move the live grid to it.
    /// Opens the bar first if closed, preserving direction. Forward → retreat (up); backward → advance (down)
    /// — vim's "`N` repeats in the opposite direction".
    func previous() {
        if !visible { open(backward: searchBackward) }
        step(forward: searchBackward)
    }

    /// Step one match `forward` (down) or backward (up) + drive the live grid to it. The single place
    /// `next()`/`previous()` resolve to a concrete direction: the controller advances/retreats its match index
    /// and ``navigateToCurrentMatch(forward:)`` moves the grid the matching way. Literal mode steps libghostty's
    /// `navigate_search:next`/`previous`; regex mode scrolls to the controller's match row.
    private func step(forward: Bool) {
        if forward { controller.next() } else { controller.previous() }
        navigateToCurrentMatch(forward: forward)
    }

    /// Drive the live grid to the controller's current match. LITERAL mode delegates to libghostty's stateful
    /// cursor (`navigate_search:next`/`previous`), which owns the amber highlight + scroll. REGEX mode can't use
    /// libghostty's literal search (no regex engine — see the header), so it scrolls the viewport to the match's
    /// row via `scroll_to_row:<row>`, keeping chevrons / ⌘G live against a count libghostty can't compute.
    private func navigateToCurrentMatch(forward: Bool) {
        guard needsRowDrivenNav else {
            model?.performSearchSurfaceAction(forward ? "navigate_search:next" : "navigate_search:previous")
            return
        }
        scrollToCurrentMatchRow()
    }

    /// Scroll the live viewport to the controller's current match row (`Match.line` indexes the same
    /// `scrollbackTextLines()` mirror the controller scanned — libghostty's `scroll_to_row:<usize>` addressing).
    /// Used by the row-driven modes (regex / whole-word). No current match (empty / unmatched query) ⇒ no-op.
    private func scrollToCurrentMatchRow() {
        guard needsRowDrivenNav, let logicalRow = controller.current?.line else { return }
        // `Match.line` indexes the UNWRAPPED scrollback mirror; libghostty's `scroll_to_row:` addresses PHYSICAL
        // grid rows (soft-wrap continuations count). Map through grid width so a heavily-wrapped pane lands on
        // the match, not N rows too high. Unknown grid width (`0`) ⇒ identity (the pre-fix row).
        let columns = model?.searchGridColumns() ?? 0
        let physicalRow = ScrollbackWrapMapper.physicalRow(
            forLogicalLine: logicalRow, in: controller.lines, columns: columns,
        )
        model?.performSearchSurfaceAction("scroll_to_row:\(physicalRow)")
    }

    /// `rectangle.stack` "search all tabs" — escalate the in-pane find to cross-tab Global Search (`⇧⌘F`),
    /// SEEDED with the current query, then dismiss this bar. The seed is read BEFORE ``close()`` clears the
    /// controller (the closure captures by value), so Global Search opens pre-filled with the live query.
    func searchAllTabs() {
        onSearchAllTabs?(controller.query)
        close()
    }

    /// × / Esc / search-all-tabs — clear the query + matches, end libghostty's search (drops every highlight),
    /// hide the bar, and RETURN keyboard first responder to the terminal surface. The buffer mirror is kept
    /// (in the controller) so re-open is cheap.
    ///
    /// The focus hand-back is load-bearing: closing tears down the focused query `TextField`'s backing NSView,
    /// but the pane's workspace focus never changed while the bar was open, so none of the surface's own reclaim
    /// paths (`isFocusedPane` didSet, mount, mouseDown, focus-follows-mouse — all gated on a focus TRANSITION or
    /// a click) fire. Without ``TerminalViewModel/reclaimKeyboardFocus()`` the window stays first responder and
    /// typing goes nowhere until the pane is clicked. Funnels all three close paths (Esc, ×, search-all-tabs).
    func close() {
        controller.clear()
        model?.performSearchSurfaceAction("end_search")
        visible = false
        model?.reclaimKeyboardFocus()
    }

    /// Push the current query into libghostty's in-surface search (it owns the amber highlight + scroll-to-
    /// match); an empty query ends the search so a stale highlight clears.
    ///
    /// REGEX (and WHOLE-WORD) mode never arms `search:` — libghostty's matcher is a literal substring scan with
    /// no regex engine and no word-boundary filter, so arming the needle would paint a misleading highlight
    /// beside the correct count and leave `navigate_search:` stepping the wrong set. These modes instead END the
    /// literal search (clearing any stale highlight) and scroll to the current match's row via `scroll_to_row`
    /// (see the header's REGEX-MODE CEILING note).
    private func armSearch() {
        let query = controller.query
        guard !query.isEmpty else {
            model?.performSearchSurfaceAction("end_search")
            return
        }
        if needsRowDrivenNav {
            model?.performSearchSurfaceAction("end_search")
            scrollToCurrentMatchRow()
        } else {
            model?.performSearchSurfaceAction("search:\(query)")
        }
    }
}

/// The find bar strip (the view). Owns only its `@FocusState` (field auto-focus) — every match / nav / toggle
/// mutation routes through ``TerminalFindBarModel`` so the GUI and the headless test stay byte-for-byte.
struct TerminalFindBar: View {
    let model: TerminalFindBarModel

    /// Pre-focuses the query field on appear (ES-E5-1: typing lands immediately).
    @FocusState private var queryFocused: Bool

    // Platform hit-target sizing: iOS uses larger plates + a wider field for touch; macOS is compact. Frame
    // dimensions are not gated by check-ds-leaks (only font/radius are).
    // iOS note: ↩ / ⇧↩ (next/prev) need a hardware keyboard; the in-bar ∧ / ∨ chevrons are the touch nav path;
    // the app-level ⌘G / ⇧⌘G chords also need a hardware keyboard (a future iOS toolbar button is TODO).
    #if os(iOS)
    private let plate: CGFloat = 34
    private let iconSize: CGFloat = 16
    private let fieldWidth: CGFloat = 200
    #else
    private let plate: CGFloat = Slate.Metric.plate
    private let iconSize: CGFloat = Slate.Metric.iconSize
    private let fieldWidth: CGFloat = 130
    #endif

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            queryField
            // find.png's THREE individually-outlined mode chips: case (`Aa`), whole-word (underlined `ab`),
            // and regex (`.*`), in that order. ``FindTogglePillTray`` lays them out identically to global-search.
            FindTogglePillTray {
                FindTogglePill(
                    label: "Aa",
                    isOn: model.controller.caseSensitive,
                    help: "Case sensitive",
                    plate: plate,
                ) {
                    model.toggleCaseSensitive()
                }
                FindTogglePill(
                    label: "ab",
                    isOn: model.controller.wholeWord,
                    help: "Whole word",
                    plate: plate,
                    underlined: true, // the whole-word chip's glyph is drawn underlined (find.png)
                ) {
                    model.toggleWholeWord()
                }
                FindTogglePill(label: ".*", isOn: model.controller.isRegex, help: "Regex (ICU)", plate: plate) {
                    model.toggleRegex()
                }
            }
            counter
            SlatePlateButton(symbol: .chevronUp, help: "Previous match (⇧⌘G)", size: iconSize, plate: plate) {
                model.previous()
            }
            SlatePlateButton(symbol: .chevronDown, help: "Next match (⌘G)", size: iconSize, plate: plate) {
                model.next()
            }
            // `rectangle.stack` button (find.png) — escalates the in-pane find to cross-tab Global Search (⇧⌘F),
            // seeded with the current query. Wired through ``TerminalFindBarModel/searchAllTabs()`` →
            // ``OverlayCoordinator/openGlobalSearch``.
            SlatePlateButton(symbol: .rectangleStack, help: "Search all tabs (⇧⌘F)", size: iconSize, plate: plate) {
                model.searchAllTabs()
            }
            SlatePlateButton(symbol: .xmark, help: "Close (Esc)", size: iconSize, plate: plate) {
                model.close()
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        // find.png: the card is delineated by FILL + drop SHADOW only — NO hairline stroke around the CARD
        // (verified by pixel-scanning: the pane→shadow gradient runs straight into the card fill, no border
        // line). Only the `Aa`/`ab`/`.*` mode chips keep their OWN hairline outlines (FindTogglePill).
        .background(Slate.Surface.raised, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusControl))
        .shadow(color: Slate.State.shadow, radius: 12, x: 0, y: 4)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / cheat-sheet idiom).
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: model.focusToken) { _, _ in
            DispatchQueue.main.async { queryFocused = true }
        }
        // ↩ → next is the field's `.onSubmit`; ⇧↩ → previous reaches THIS container (a single-line field does
        // not submit on shift+return). Guard on `.shift` so the two never double-fire (the PaletteView idiom).
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            model.previous()
            return .handled
        }
        #if os(macOS)
        .onExitCommand { model.close() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            model.close()
            return .handled
        }
        #endif
    }

    // MARK: - Query field

    private var queryField: some View {
        TextField("Find", text: queryBinding)
            .textFieldStyle(.plain)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.primary)
            .tint(Slate.State.accent) // the active caret is the accent colour
            .focused($queryFocused)
            .frame(width: fieldWidth)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            // find.png: the query text sits in its OWN delineated inset — a distinct FILLED gray rounded field
            // INSIDE the card (not flush). The card is `Surface.raised` (≈ white in light themes), so a flush
            // `Surface.face` field reads as near-invisible; instead the field wears `State.selected`, a
            // translucent neutral wash. CROSS-THEME caveat (Batch-5b): `State.selected` is a BLACK wash in light
            // (composites DARKER than the card → recessed inset, matching find.png) but WHITE in dark
            // (composites LIGHTER → reads RAISED, not recessed). No single solid/wash token is reliably
            // recessed-AND-visible on both themes (the only darker-than-card token in dark, `Surface.face`/the
            // backdrop, is near-invisible in light). So rather than chase a darker fill we DELINEATE the field
            // with its own inner `Line.subtle` hairline — a hard boundary that reads as a distinct inset
            // whichever way the fill contrasts. INNER field only; the card's no-border fill+shadow chrome
            // (Batch-4) is NOT re-stroked (outer card stays borderless).
            .background(Slate.State.selected, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .onSubmit { model.next() } // plain ↩ → next match
    }

    /// Two-way binding into the controller's query (read the live value, write through `setQuery` so every
    /// keystroke recomputes the counter + re-arms the libghostty highlight).
    private var queryBinding: Binding<String> {
        Binding(get: { model.controller.query }, set: { model.setQuery($0) })
    }

    // MARK: - N of M counter

    @ViewBuilder private var counter: some View {
        if let label = counterText {
            Text(label)
                .font(.system(size: Slate.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Slate.Metric.space1)
        }
    }

    /// `N of M` when there is a current match; a muted "No results" when the query is non-empty but matched
    /// nothing; `nil` (hidden) for an empty query — matching `controller.positionLabel`.
    private var counterText: String? {
        if let position = model.controller.positionLabel {
            return "\(position.current) of \(position.total)"
        }
        if !model.controller.query.isEmpty { return "No results" }
        return nil
    }
}

/// LOCKED MODE-PILL RENDERING — screenshot-matched, final; do NOT re-litigate.
/// `find.png` AND `global-search.png` (verified by zooming both) show the `Aa` / underlined-`ab` / `.*` mode
/// pills as INDIVIDUALLY-OUTLINED rounded chips — each with its OWN resting plate + `Line.subtle` hairline,
/// gapped, sitting DIRECTLY on the bar. There is NO shared segmented backing tray. Reviews oscillated (bare
/// glyphs → resting plates → shared tray → individually-outlined chips); THIS is the resolved reading — a
/// future re-flag of "shared tray" or "bare glyphs" is ALREADY-RESOLVED, not a new finding.
/// Non-negotiable invariants: (1) every idle chip is visually DELINEATED (own plate + hairline, never a bare
/// glyph); (2) the find bar and global-search query bar render the pills IDENTICALLY — both via this type +
/// ``FindTogglePill``.
///
/// `FindTogglePillTray` is therefore just a TRANSPARENT layout container — an `HStack` with the screenshot's
/// inter-chip gap and NO background / border of its own (delineation lives on each ``FindTogglePill``). Reused
/// by BOTH the find bar and the global-search query bar (the EXACT same control). `Slate.*` tokens only.
struct FindTogglePillTray<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // No shared plate/border here — the chips delineate themselves; the tray only spaces them with a gap.
        HStack(spacing: Slate.Metric.space1) {
            content
        }
    }
}

/// A compact `Aa` / `ab` / `.*` toggle pill (the find-bar mode buttons), inside a ``FindTogglePillTray``.
/// LOCKED rendering (see the tray's doc comment): each chip is INDIVIDUALLY outlined. idle → its OWN
/// `Surface.face` plate + `Line.subtle` hairline (never a bare glyph); hover → a `State.hover` plate (border
/// held); on → accent text on an `accentMuted` wash + an accent hairline ring. No shared backing tray.
/// Factored to file scope (internal) so the WI-4 GlobalSearch surface reuses the EXACT pill. `Slate.*` tokens
/// only.
struct FindTogglePill: View {
    let label: String
    let isOn: Bool
    var help: String?
    var plate: CGFloat = Slate.Metric.plate
    /// Underline the glyph (the whole-word `ab` chip draws underlined; `Aa` / `.*` pass `false`).
    var underlined: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .underline(underlined)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Slate.State.accent : Slate.Text.secondary)
                .frame(minWidth: plate, minHeight: plate)
                .padding(.horizontal, Slate.Metric.space1)
                .background(
                    // Each chip carries its OWN resting plate (find.png / global-search.png): idle = a subtle
                    // `Surface.face` plate, hover = a `State.hover` plate, on = the accent wash. No shared tray.
                    isOn ? Slate.State.accentMuted : (hovering ? Slate.State.hover : Slate.Surface.face),
                    in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall),
                )
                .overlay(
                    // Every chip is individually outlined: idle/hover wear a `Line.subtle` hairline so the chip is
                    // delineated (never a bare glyph); the ON chip swaps in the accent ring.
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .strokeBorder(
                            isOn ? Slate.State.accent.opacity(0.5) : Slate.Line.subtle,
                            lineWidth: Slate.Metric.hairline,
                        ),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp(help)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }
}
#endif
