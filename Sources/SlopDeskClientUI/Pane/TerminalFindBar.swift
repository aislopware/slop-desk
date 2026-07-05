// TerminalFindBar — the in-pane ⌘F find overlay (E5 / WI-3). A THIN SwiftUI driver over the PURE
// ``TerminalSearchController`` (count / N-of-M / next-prev-wrap — the single source of truth for the match
// math) plus libghostty's OWN in-surface search bindings (`search:` / `navigate_search:` / `end_search`,
// reached through ``TerminalViewModel/performSearchSurfaceAction(_:)``), which own the amber highlight +
// scroll-to-match in the live grid. The counter counts the `scrollbackTextLines()` snapshot taken when the
// bar opened (divergence #2 in plans/E5.md): the count is the mirror's; the highlight is libghostty's — they
// agree in the common case (same buffer), and the mirror refreshes on open + on the `Aa` / `.*` toggles.
//
// REGEX-MODE CEILING (ES-E5-4 honesty fix). libghostty's in-surface search is a LITERAL substring matcher —
// it has NO regex engine (`changeNeedle` compares needles case-insensitively; no pattern compilation). So in
// `.*` mode we must NOT arm `search:<pattern>` (it would highlight the literal pattern text — usually 0 hits —
// while the counter reports the real regex match count, and every `navigate_search:` would then move nothing:
// a lying counter beside dead chevrons / ⌘G). Instead, regex mode is driven ENTIRELY from the controller's
// own match positions: arming `end_search` (clearing any stale literal highlight) and issuing
// `scroll_to_row:<Match.line>` on open / next / previous so the viewport actually scrolls to each regex match
// (the chevrons / ⌘G / ⇧⌘G stay live). `Match.line` is the 0-based row into the same `scrollbackTextLines()`
// mirror the controller scanned, which is the row index libghostty's `scroll_to_row:<usize>` addresses. The
// one thing regex mode CANNOT have is the amber per-glyph highlight (libghostty can't render regex spans) —
// that is the documented ceiling; the counter stays accurate and nav stays functional regardless. A direct
// corollary of that same ceiling: when several regex matches fall on the SAME already-visible row, next/previous
// re-issue the IDENTICAL `scroll_to_row:<row>`, so the "k of N" counter advances with NO visible viewport
// change — the matches are already on-screen and (lacking the per-span highlight) nothing on the row moves.
// This is expected, not a stall: it is the literal-highlight ceiling surfacing at row granularity, not a bug.
// Literal mode is unchanged: it arms `search:` + `navigate_search:next`/`previous`.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Slate.*` tokens ONLY — raw
// font / radius literals fail `scripts/check-ds-leaks.sh`):
//   [ query field ][ Aa case pill ][ ab whole-word pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ]
//   [ ▣ search-all-tabs ][ × close ]
// (the `rectangle.stack` "search all tabs" button escalates to cross-tab Global Search ⇧⌘F — see
// ``TerminalFindBarModel/searchAllTabs()``)
// (ES-E5-2 requires the `N of M` counter; `find.png` does not show a separate inline counter for the captured
// query, so the screenshot is NOT the source for the counter's placement. We keep it before the nav chevrons
// as a reasonable home for the required count.)
//
// Behaviour (ES-E5-1..4): auto-focus the field on appear (pre-focused per spec); live query → recompute +
// re-arm highlight; ↩ / ⇧↩ next / prev; `Aa` / `.*` toggle case / regex; Esc (or ×) closes + clears all
// highlights. The bar OWNS no match math — `TerminalFindBarModel` wraps the controller + a weak model ref so
// the GUI and the headless unit test (`TerminalFindBarModelTests`) drive the exact same logic.
//
// Hang-safety: NO `GhosttySurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// The find bar's view-model: the PURE ``TerminalSearchController`` (count / nav) + a weak pane
/// ``TerminalViewModel`` ref (the scrollback mirror + the libghostty `search:` passthrough). `@Observable`
/// so the bar re-renders on every query / toggle / nav; held as `@State` by ``TerminalLeafView`` and wired to
/// the pane's `onRequestFind` / `onRequestFindNext` / `onRequestFindPrev` callbacks. Weak model ref so a
/// torn-down pane is never kept alive by the bar (the leaf is `.id(PaneID)`-keyed — an identity hazard).
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
    /// The SEARCH DIRECTION the bar was opened in (E17 ES-E17-2 / WI-5): `/`-opened (and ⌘F) search FORWARD
    /// (`false`); a copy-mode `?` opens it BACKWARD (`true`, via ``open(backward:)``). It biases vi's `n`/`N`:
    /// ``next()`` (vi `n`) steps in this direction, ``previous()`` (vi `N`) against it — so after `?foo`, `n`
    /// walks UP the buffer and `N` walks down (vim parity), while a forward search keeps the natural sense.
    private(set) var searchBackward = false
    /// The pane's terminal model — the scrollback mirror + the libghostty `search:` / `navigate_search:` /
    /// `end_search` passthrough. Weak (owned by the live session); `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private weak var model: TerminalViewModel?

    /// E5 "search all tabs" escalation — the `rectangle.stack` button between the next-match chevron and the
    /// close × (`find.png`). Opens cross-tab Global Search (⇧⌘F) seeded with the live find query. Wired by
    /// ``TerminalLeafView`` to ``OverlayCoordinator/openGlobalSearch(seed:)``; `nil` in previews / tests ⇒ the
    /// button still dismisses the bar but the escalation no-ops. Pure wiring, so `@ObservationIgnored`.
    @ObservationIgnored var onSearchAllTabs: ((String) -> Void)?

    init() {}

    /// Bind (or unbind, with `nil`) the pane's terminal model. ``TerminalLeafView`` calls this when it wires /
    /// clears the `onRequestFind*` callbacks (per-pane, so a torn-down leaf can't drive a dead model).
    func attach(_ model: TerminalViewModel?) { self.model = model }

    /// ⌘F / Find… — open (or re-focus) the bar, refreshing the scrollback mirror snapshot the counter counts
    /// (divergence #2: libghostty owns the live in-surface highlight; this snapshot owns the `N of M` count).
    /// `backward` seeds the SEARCH DIRECTION (default forward for ⌘F / `/`; a copy-mode `?` passes `true`) so the
    /// subsequent `n`/`N` step relative to it — see ``searchBackward`` / ``next()`` / ``previous()``.
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

    /// `ab` (underlined) — flip whole-word matching, refresh the mirror, recompute + re-arm. Like regex, this
    /// mode is one libghostty's LITERAL in-surface search cannot express (it has no word-boundary filter), so
    /// the bar drives nav from its own match rows via `scroll_to_row` rather than arming `search:` — otherwise
    /// libghostty would highlight (and `navigate_search:` would step through) every substring, diverging from
    /// the whole-word counter. See ``needsRowDrivenNav`` / the header's REGEX-MODE CEILING note.
    func toggleWholeWord() {
        controller.setWholeWord(!controller.wholeWord)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// Whether the controller's current mode CANNOT be expressed FAITHFULLY by libghostty's literal in-surface
    /// search, so the bar must drive navigation from its OWN match rows via `scroll_to_row:` instead of arming
    /// `search:` / `navigate_search:`. True for regex (no regex engine), whole-word (no word-boundary filter),
    /// AND case-SENSITIVE (libghostty's matcher is HARD-WIRED case-insensitive — `std.ascii.indexOfIgnoreCase`).
    /// Arming `search:` in case-sensitive mode would amber-highlight (and `navigate_search:` would step) extra
    /// case-folded occurrences the controller's case-sensitive counter says don't exist — the N-of-M counter,
    /// the highlight, and the chevrons would permanently disagree. This mirrors ``GlobalSearchController``'s
    /// click-to-line fix, which already routes case-sensitive jumps through `end_search` + `scroll_to_row`.
    private var needsRowDrivenNav: Bool { controller.isRegex || controller.wholeWord || controller.caseSensitive }

    /// ↩ / ⌘G / vi `n` — step to the next match IN THE SEARCH DIRECTION + move the live grid to it. Opens the
    /// bar first if it is closed (faithful "find next opens find"), PRESERVING the current direction. For a
    /// forward search this advances (down); for a `?`-opened backward search it RETREATS (up) — vim's "`n`
    /// repeats the search in its original direction".
    func next() {
        if !visible { open(backward: searchBackward) }
        step(forward: !searchBackward)
    }

    /// ⇧↩ / ⇧⌘G / vi `N` — step to the next match AGAINST the search direction + move the live grid to it.
    /// Opens the bar first if it is closed, preserving direction. Forward search → retreat (up); backward search
    /// → advance (down) — vim's "`N` repeats the search in the opposite direction".
    func previous() {
        if !visible { open(backward: searchBackward) }
        step(forward: searchBackward)
    }

    /// Step the selection one match `forward` (down) or backward (up) + drive the live grid to it. The single
    /// place `next()`/`previous()` resolve to a concrete direction: the controller advances/retreats its match
    /// index and ``navigateToCurrentMatch(forward:)`` moves the grid the matching way. Literal mode steps
    /// libghostty's own `navigate_search:next`/`previous`; regex mode scrolls to the controller's match row.
    private func step(forward: Bool) {
        if forward { controller.next() } else { controller.previous() }
        navigateToCurrentMatch(forward: forward)
    }

    /// Drive the live grid to the controller's current match. LITERAL mode delegates to libghostty's own
    /// stateful cursor (`navigate_search:next`/`previous`), which owns the amber highlight + scroll. REGEX mode
    /// cannot use libghostty's literal search at all (no regex engine — see the header) so it scrolls the
    /// viewport directly to the match's row via `scroll_to_row:<row>`, keeping the chevrons / ⌘G live against a
    /// count libghostty can't itself compute.
    private func navigateToCurrentMatch(forward: Bool) {
        guard needsRowDrivenNav else {
            model?.performSearchSurfaceAction(forward ? "navigate_search:next" : "navigate_search:previous")
            return
        }
        scrollToCurrentMatchRow()
    }

    /// Scroll the live viewport to the controller's current match row (`Match.line` indexes the same
    /// `scrollbackTextLines()` mirror the controller scanned, matching libghostty's `scroll_to_row:<usize>`
    /// addressing). Used by the row-driven modes (regex / whole-word) that libghostty's literal search cannot
    /// itself express. No current match (empty / unmatched query) ⇒ nothing to scroll to.
    private func scrollToCurrentMatchRow() {
        guard needsRowDrivenNav, let logicalRow = controller.current?.line else { return }
        // `Match.line` indexes the UNWRAPPED scrollback mirror; libghostty's `scroll_to_row:` addresses PHYSICAL
        // grid rows (soft-wrap continuations count). Map through the grid width so a heavily-wrapped pane lands
        // on the match instead of N rows too high. Unknown grid width (`0`) ⇒ identity (the pre-fix row).
        let columns = model?.searchGridColumns() ?? 0
        let physicalRow = ScrollbackWrapMapper.physicalRow(
            forLogicalLine: logicalRow, in: controller.lines, columns: columns,
        )
        model?.performSearchSurfaceAction("scroll_to_row:\(physicalRow)")
    }

    /// `rectangle.stack` "search all tabs" — escalate the in-pane find to cross-tab Global Search (`⇧⌘F`),
    /// SEEDED with the current query, then dismiss this bar. `find.png` places the button between the
    /// next-match chevron and the close ×. The seed is read BEFORE
    /// ``close()`` clears the controller (the closure captures the string by value), so Global Search opens
    /// pre-filled with whatever the user was finding.
    func searchAllTabs() {
        onSearchAllTabs?(controller.query)
        close()
    }

    /// × / Esc / search-all-tabs — clear the query + matches, end libghostty's search (drops every highlight),
    /// hide the bar, and RETURN the keyboard first responder to the terminal surface. The buffer mirror is kept
    /// (in the controller) so a re-open is cheap.
    ///
    /// The focus hand-back is load-bearing: closing tears down the focused query `TextField`'s backing NSView,
    /// but the pane's workspace focus never changed while the bar was open, so none of the surface's own reclaim
    /// paths (the `isFocusedPane` didSet, mount, mouseDown, focus-follows-mouse — all gated on a focus TRANSITION
    /// or a click) fire. Without ``TerminalViewModel/reclaimKeyboardFocus()`` the window stays first responder and
    /// typing goes nowhere until the pane is clicked. This funnels all three close paths (Esc, ×, search-all-tabs
    /// via ``searchAllTabs()``).
    func close() {
        controller.clear()
        model?.performSearchSurfaceAction("end_search")
        visible = false
        model?.reclaimKeyboardFocus()
    }

    /// Push the current query into libghostty's own in-surface search (it owns the amber highlight + the
    /// scroll-to-match); an empty query ends the search so a stale highlight clears.
    ///
    /// REGEX (and WHOLE-WORD) mode never arms `search:` — libghostty's matcher is a plain literal substring
    /// scan with no regex engine and no word-boundary filter, so arming the needle would paint a misleading
    /// highlight beside the controller's (correct) count and leave `navigate_search:` stepping the wrong set.
    /// Instead these modes END the literal search (clearing any stale highlight) and scroll the viewport to the
    /// current match's row via `scroll_to_row` (see the header's REGEX-MODE CEILING note).
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

    /// Pre-focuses the query field on appear (ES-E5-1: the field is pre-focused so typing lands immediately).
    @FocusState private var queryFocused: Bool

    // Platform hit-target sizing: iOS uses larger plates + a wider field for touch; macOS is compact (find.png
    // is a tight horizontal strip). Frame dimensions are not gated by check-ds-leaks (only font/radius are).
    // iOS note: ↩ / ⇧↩ (next/prev) work on a hardware keyboard; the in-bar ∧ / ∨ chevrons are the touch path
    // for nav, and the app-level ⌘G / ⇧⌘G chords need a hardware keyboard (a future iOS toolbar button is TODO).
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
            // find.png shows a `rectangle.stack` button between the next-chevron and the close ×. It ESCALATES
            // the in-pane find to cross-tab Global Search (⇧⌘F), seeded with the current query. Wired through
            // ``TerminalFindBarModel/searchAllTabs()`` → ``OverlayCoordinator/openGlobalSearch``.
            SlatePlateButton(symbol: .rectangleStack, help: "Search all tabs (⇧⌘F)", size: iconSize, plate: plate) {
                model.searchAllTabs()
            }
            SlatePlateButton(symbol: .xmark, help: "Close (Esc)", size: iconSize, plate: plate) {
                model.close()
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        // find.png: the floating find-bar card is delineated by its FILL + drop SHADOW only — there is NO
        // hairline stroke around the CARD (verified by pixel-scanning find.png: the pane→shadow gradient
        // transitions straight into the card fill with no border line). Only the `Aa`/`ab`/`.*` mode chips keep
        // their OWN individual hairline outlines (FindTogglePill); the card itself wears no border/overlay.
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
            // INSIDE the find-bar card (NOT flush on it). The card itself is `Surface.raised` (≈ white/elevated
            // in light themes), so a flush `Surface.face` field reads as near-invisible there; instead the field
            // wears `State.selected` — a translucent neutral wash that composites over the `element` card to a
            // gray inset. CROSS-THEME caveat (Batch-5b): `State.selected` is a BLACK wash in light themes (so the
            // field composites DARKER than the card → a recessed inset, matching find.png) but a WHITE wash in
            // dark themes (so it composites LIGHTER than the card — which on its OWN reads RAISED, not recessed).
            // No single solid/wash token is reliably recessed-AND-visible on both themes (the only darker-than-
            // card token in dark — `Surface.face`/the backdrop — is near-invisible in light). So rather than
            // chase a darker fill, we DELINEATE the field with its own inner `Line.subtle` hairline: a hard field
            // boundary that reads as a distinct inset REGARDLESS of which way the fill contrasts, keeping the
            // query field clearly delineated on every theme. This is the INNER field only — the card's
            // no-border / fill+shadow chrome (Batch-4) is NOT re-stroked (the outer card stays borderless).
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

/// LOCKED MODE-PILL RENDERING — screenshot-matched, final decision; do NOT re-litigate.
/// What `find.png` AND `global-search.png` actually show (verified by zooming both): the `Aa` / underlined-`ab`
/// / `.*` mode pills are INDIVIDUALLY-OUTLINED rounded chips — each carries its OWN resting plate + its OWN
/// `Line.subtle` hairline border, separated by a visible gap, sitting DIRECTLY on the bar. There is NO shared
/// segmented backing tray fusing them into one control. Successive reviews oscillated (bare glyphs → resting
/// plates → one shared tray → individually-outlined chips); THIS is the resolved reading — a future re-flag of
/// "should be a shared tray" or "should be bare glyphs" is ALREADY-RESOLVED, not a new finding.
/// Non-negotiable invariants: (1) every idle chip is visually DELINEATED (own plate + hairline, never a bare
/// glyph); (2) the find bar and the global-search query bar render the pills IDENTICALLY — both go through this
/// type + ``FindTogglePill``.
///
/// `FindTogglePillTray` is therefore just a TRANSPARENT layout container — an `HStack` with the screenshot's
/// inter-chip gap and NO background / border of its own (the delineation lives on each ``FindTogglePill``).
/// Reused by BOTH the find bar and the global-search query bar (the EXACT same control). `Slate.*` tokens only.
struct FindTogglePillTray<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // No shared plate/border here — the chips delineate themselves; the tray only spaces them with a gap.
        HStack(spacing: Slate.Metric.space1) {
            content
        }
    }
}

/// A compact `Aa` / `ab` / `.*` toggle pill (the find-bar mode buttons), laid out inside a ``FindTogglePillTray``.
/// LOCKED rendering (see the tray's doc comment — screenshot-matched, final): each chip is INDIVIDUALLY
/// outlined. idle → its OWN `Surface.face` resting plate + a `Line.subtle` hairline border (delineated, never a
/// bare glyph); hover → a `State.hover` plate (border held); on → accent text on an `accentMuted` wash + an
/// accent hairline ring. There is NO shared backing tray — `find.png` / `global-search.png` show detached,
/// individually-bordered chips with gaps between them. Factored to file scope (internal) so the WI-4
/// GlobalSearch surface reuses the EXACT pill (the two surfaces render identically). `Slate.*` tokens only.
struct FindTogglePill: View {
    let label: String
    let isOn: Bool
    var help: String?
    var plate: CGFloat = Slate.Metric.plate
    /// Underline the glyph (the whole-word `ab` chip in find.png / global-search.png draws underlined). The
    /// `Aa` / `.*` chips pass `false` so only the whole-word chip wears the underline.
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
