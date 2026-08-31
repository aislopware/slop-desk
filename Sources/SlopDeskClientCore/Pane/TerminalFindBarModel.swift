// TerminalFindBarModel — the in-pane ⌘F find bar's DRIVER: the PURE ``TerminalSearchController``
// (count / N-of-M / next-prev-wrap) plus a weak pane ``TerminalViewModel`` ref (the scrollback mirror
// and the terminal surface's own in-grid search bindings). No view, no framework — which is why it is here
// rather than beside the bar that draws it (docs/56 §3: a UI target holds views only).
//
// Its own header always said the reason: "the GUI and the headless unit test drive the exact same
// logic". That was true of the model and false of its address — it sat in `SlopDeskClientUI` and
// imported SwiftUI for exactly one symbol, `@Observable`, which is the `Observation` module and
// reachable from every floor. So the phone's find bar and the Mac's would each have had to hold their
// own, which is the duplicate `CLAUDE.md` bans by name.
//
// REGEX-MODE CEILING (an honesty fix, carried over verbatim from the view file this left). The engine
// ships no search at all (`libghostty-vt` has none), so the terminal surface's own in-grid matcher
// (`slopdesk-vterm`'s `search.rs`) is what this arms, and it is a LITERAL substring matcher with NO
// regex engine (`changeNeedle` compares case-insensitively; no pattern compilation). So in `.*` mode we must NOT arm `search:<pattern>` — it
// would highlight the literal pattern text (usually 0 hits) while the counter reports the real regex
// count, and `navigate_search:` would move nothing (a lying counter beside dead chevrons / ⌘G). Instead
// regex mode is driven ENTIRELY from the controller's match positions: `end_search` (clears any stale
// highlight) + `scroll_to_row:<Match.line>` on open / next / previous so the viewport scrolls to each
// match (chevrons / ⌘G / ⇧⌘G stay live). `Match.line` is the 0-based row into the same
// `scrollbackLines()` mirror the controller scanned, and the mirror carries the SCREEN row
// `scroll_to_row:<usize>` addresses.
// Regex mode CANNOT have the amber per-glyph highlight (the surface's literal matcher can't render regex spans): that is
// the documented ceiling; counter + nav stay correct. Corollary: when several matches share one
// already-visible row, next/previous re-issue the IDENTICAL `scroll_to_row:<row>` — the "k of N"
// counter advances with no viewport change. Expected, not a stall. Literal mode is unchanged:
// `search:` + `navigate_search:next`/`previous`.
//
// Hang-safety: NO `TerminalSurface` / VideoToolbox / Metal is touched here — the model only calls the
// terminal seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a
// headless surface.
//
// WHERE THE RULES LIVE. Four of the decisions this file used to make are `slopdesk_workspace::find_bar`'s
// and reached through doors: the five binding-action SPELLINGS, the three-flag test for whether
// the surface's literal matcher can be trusted with the mode, the branch a keystroke arms, and vi's `n`/`N` against the
// direction the bar opened in. What stayed is the `@Observable` lifetime — the weak model ref, the
// focus token, the focus hand-back on close — which is Swift by necessity, not by habit.

import Observation
import SlopDeskWorkspaceCore

// MARK: - The driver

/// The find bar's view-model: the PURE ``TerminalSearchController`` (count / nav) + a weak pane
/// ``TerminalViewModel`` ref (scrollback mirror + the surface's `search:` passthrough). `@Observable` so
/// the bar re-renders on every query / toggle / nav; held as `@State` by the leaf that mounts the bar,
/// wired to the pane's `onRequestFind` / `onRequestFindNext` / `onRequestFindPrev`. Weak model ref so a
/// torn-down pane isn't kept alive by the bar (the leaf is `.id(PaneID)`-keyed — an identity hazard).
@MainActor
@Observable
package final class TerminalFindBarModel {
    /// Whether the bar is shown over its pane (the leaf's top-trailing overlay gate).
    package var visible = false
    /// The PURE match engine — the single source of truth for the counter + nav. `private(set)`: only the
    /// model's own methods mutate it (each mutation notifies `@Observable`, so the bar re-renders).
    package private(set) var controller = TerminalSearchController()
    /// Bumped on every (re)open so the view re-asserts its focus even when the bar is already mounted
    /// (⌘F while the bar is open should re-focus the field, but an appear hook won't fire again).
    package private(set) var focusToken = 0
    /// The SEARCH DIRECTION the bar opened in: `/` and ⌘F search FORWARD (`false`); a
    /// copy-mode `?` opens BACKWARD (`true`, via ``open(backward:)``). Biases vi's `n`/`N`: ``next()`` (`n`)
    /// steps in this direction, ``previous()`` (`N`) against it — so after `?foo`, `n` walks UP and `N` down
    /// (vim parity); a forward search keeps the natural sense.
    package private(set) var searchBackward = false
    /// The pane's terminal model — the scrollback mirror + the surface's own search passthrough. Weak (owned
    /// by the live session); `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private weak var model: TerminalViewModel?

    /// The scrollback snapshot the controller is scanning, WITH each line's screen rows.
    ///
    /// The controller takes text alone — it is a pure matcher and has no business holding a row number
    /// it would have to keep in step with its own index. So the records stay here, taken in the same
    /// breath as `setLines`, and ``scrollToCurrentMatchRow()`` reads the row off THIS by the index the
    /// controller reported. Two snapshots taken at two moments is the drift that shape avoids.
    /// `@ObservationIgnored`: nothing renders it.
    @ObservationIgnored private var mirror: [TerminalScrollbackLine] = []

    /// "search all tabs" escalation — the `rectangle.stack` button (`find.png`). Opens cross-tab Global
    /// Search (⇧⌘F) seeded with the live query. Wired by the leaf to
    /// ``OverlayCoordinator/openGlobalSearch(seed:)``; `nil` in previews / tests ⇒ the button still dismisses
    /// the bar but the escalation no-ops. Pure wiring, so `@ObservationIgnored`.
    @ObservationIgnored package var onSearchAllTabs: ((String) -> Void)?

    package init() {}

    /// Bind (or unbind, with `nil`) the pane's terminal model. The leaf calls this when it wires /
    /// clears the `onRequestFind*` callbacks (per-pane, so a torn-down leaf can't drive a dead model).
    package func attach(_ model: TerminalViewModel?) { self.model = model }

    /// Re-snapshots the scrollback into both the controller (text) and ``mirror`` (rows), in one read.
    ///
    /// Every mode flip refreshes it as well as every open, which is divergence #2 in the header: the
    /// surface owns the live highlight, this snapshot owns the `N of M` count, and a count computed
    /// against a mirror the shell has since scrolled is a count of something that is no longer there.
    private func refreshMirror() {
        mirror = model?.searchScrollbackLines() ?? []
        controller.setLines(mirror.text)
    }

    /// ⌘F / Find… — open (or re-focus) the bar, refreshing the scrollback mirror snapshot the counter counts
    /// (divergence #2: the surface owns the live highlight, this snapshot owns the `N of M` count). `backward`
    /// seeds the SEARCH DIRECTION (default forward; a copy-mode `?` passes `true`) so `n`/`N` step relative to
    /// it — see ``searchBackward`` / ``next()`` / ``previous()``.
    package func open(backward: Bool = false) {
        searchBackward = backward
        refreshMirror()
        armSearch()
        visible = true
        focusToken &+= 1
    }

    /// Live query edit — recompute matches (counter) + re-arm the surface's in-grid highlight.
    package func setQuery(_ text: String) {
        controller.setQuery(text)
        armSearch()
    }

    /// `Aa` — flip case sensitivity, refresh the mirror (divergence #2), recompute + re-arm.
    package func toggleCaseSensitive() {
        controller.setCaseSensitive(!controller.caseSensitive)
        refreshMirror()
        armSearch()
    }

    /// `.*` — flip regex mode (the `regex` crate's dialect: linear-time, no lookaround), refresh the
    /// mirror, recompute + re-arm.
    package func toggleRegex() {
        controller.setRegex(!controller.isRegex)
        refreshMirror()
        armSearch()
    }

    /// `ab` (underlined) — flip whole-word matching, refresh the mirror, recompute + re-arm. Like regex,
    /// the surface's LITERAL search can't express this (no word-boundary filter), so the bar drives nav from its
    /// own match rows via `scroll_to_row` rather than arming `search:` — else the surface would highlight (and
    /// `navigate_search:` step through) every substring, diverging from the whole-word counter. See
    /// ``needsRowDrivenNav`` / the header's REGEX-MODE CEILING note.
    package func toggleWholeWord() {
        controller.setWholeWord(!controller.wholeWord)
        refreshMirror()
        armSearch()
    }

    /// Whether the controller's current mode CANNOT be expressed FAITHFULLY by the surface's literal search, so
    /// the bar must drive nav from its OWN match rows via ``TerminalSearchSurfaceAction/scrollToRow(_:)``
    /// instead of `search:` / `navigate_search:`.
    ///
    /// Which three flags say that, and why the case-sensitive one is among them, is
    /// `slopdesk_workspace::find_bar::needs_row_driven_nav` — the same rule
    /// ``GlobalSearchController``'s click-to-line jump reads, so the two surfaces cannot start
    /// disagreeing about which modes the surface's literal search can be trusted with.
    private var needsRowDrivenNav: Bool {
        TerminalSearchSurfaceAction.needsRowDrivenNav(
            isRegex: controller.isRegex,
            wholeWord: controller.wholeWord,
            caseSensitive: controller.caseSensitive,
        )
    }

    /// ↩ / ⌘G / vi `n` — step to the next match IN THE SEARCH DIRECTION + move the live grid to it. Opens the
    /// bar first if closed, preserving direction. Forward search advances (down); a `?`-opened backward search
    /// retreats (up) — vim's "`n` repeats in its original direction".
    package func next() {
        if !visible { open(backward: searchBackward) }
        step(forward: TerminalSearchSurfaceAction.forwardStep(repeatingSameWay: true, searchBackward: searchBackward))
    }

    /// ⇧↩ / ⇧⌘G / vi `N` — step to the next match AGAINST the search direction + move the live grid to it.
    /// Opens the bar first if closed, preserving direction. Forward → retreat (up); backward → advance (down)
    /// — vim's "`N` repeats in the opposite direction".
    package func previous() {
        if !visible { open(backward: searchBackward) }
        step(forward: TerminalSearchSurfaceAction.forwardStep(repeatingSameWay: false, searchBackward: searchBackward))
    }

    /// Step one match `forward` (down) or backward (up) + drive the live grid to it. The single place
    /// `next()`/`previous()` resolve to a concrete direction: the controller advances/retreats its match index
    /// and ``navigateToCurrentMatch(forward:)`` moves the grid the matching way. Literal mode steps the surface's
    /// own search cursor; the row-driven modes scroll to the controller's match row.
    private func step(forward: Bool) {
        if forward { controller.next() } else { controller.previous() }
        navigateToCurrentMatch(forward: forward)
    }

    /// Drive the live grid to the controller's current match. LITERAL mode delegates to the surface's stateful
    /// cursor (``TerminalSearchSurfaceAction/navigate(forward:)``), which owns the amber highlight + scroll.
    /// The row-driven modes can't use the surface's literal search (see the header), so they scroll the viewport
    /// to the match's row, keeping chevrons / ⌘G live against a count the surface can't compute.
    private func navigateToCurrentMatch(forward: Bool) {
        guard needsRowDrivenNav else {
            perform(.navigate(forward: forward))
            return
        }
        scrollToCurrentMatchRow()
    }

    /// Scroll the live viewport to the controller's current match row (`Match.line` indexes the same
    /// ``mirror`` the controller scanned — `scroll_to_row:<usize>`'s SCREEN-row addressing).
    /// Used by the row-driven modes (regex / whole-word / case-sensitive). No current match (empty / unmatched
    /// query) ⇒ no-op.
    private func scrollToCurrentMatchRow() {
        guard needsRowDrivenNav, let line = controller.current?.line else { return }
        // `Match.line` indexes the UNWRAPPED mirror; `scroll_to_row:` addresses SCREEN rows (soft-wrap
        // continuations count). The mirror carries the engine's own row per line, so this is a lookup rather
        // than the grid-width estimate it used to be. An index the mirror no longer holds scrolls NOWHERE —
        // the scrollback moved under the match, and landing on a clamped row would be landing on a lie.
        guard let row = mirror.row(forLine: line) else { return }
        perform(.scrollToRow(row))
    }

    /// `rectangle.stack` "search all tabs" — escalate the in-pane find to cross-tab Global Search (`⇧⌘F`),
    /// SEEDED with the current query, then dismiss this bar. The seed is read BEFORE ``close()`` clears the
    /// controller (the closure captures by value), so Global Search opens pre-filled with the live query.
    package func searchAllTabs() {
        onSearchAllTabs?(controller.query)
        close()
    }

    /// × / Esc / search-all-tabs — clear the query + matches, end the surface's search (drops every highlight),
    /// hide the bar, and RETURN keyboard first responder to the terminal surface. The buffer mirror is kept
    /// (in the controller) so re-open is cheap.
    ///
    /// The focus hand-back is load-bearing: closing tears down the focused query field's backing view, but the
    /// pane's workspace focus never changed while the bar was open, so none of the surface's own reclaim paths
    /// (`isFocusedPane` didSet, mount, mouseDown, focus-follows-mouse — all gated on a focus TRANSITION or a
    /// click) fire. Without ``TerminalViewModel/reclaimKeyboardFocus()`` the window stays first responder and
    /// typing goes nowhere until the pane is clicked. Funnels all three close paths (Esc, ×, search-all-tabs).
    package func close() {
        controller.clear()
        perform(.end)
        visible = false
        model?.reclaimKeyboardFocus()
    }

    /// Push the current query into the surface's own in-grid search (it owns the amber highlight + scroll-to-
    /// match); an empty query ends the search so a stale highlight clears.
    ///
    /// The ROW-DRIVEN modes never arm `search:` — the surface's matcher is a literal, case-insensitive substring
    /// scan with no word-boundary filter, so arming the needle would paint a misleading highlight beside the
    /// correct count and leave `navigate_search:` stepping the wrong set. They instead END the literal search
    /// (clearing any stale highlight) and scroll to the current match's row (see the header's REGEX-MODE
    /// CEILING note).
    private func armSearch() {
        let query = controller.query
        switch TerminalSearchSurfaceAction.arming(
            queryEmpty: query.isEmpty,
            isRegex: controller.isRegex,
            wholeWord: controller.wholeWord,
            caseSensitive: controller.caseSensitive,
        ) {
        case .search:
            perform(.search(needle: query))
        case .endThenScroll:
            perform(.end)
            scrollToCurrentMatchRow()
        case .end:
            perform(.end)
        }
    }

    /// The ONE place a ``TerminalSearchSurfaceAction`` becomes a string on the way to the terminal surface.
    ///
    /// An action the door does not spell is not sent: handing `performBindingAction` a blank string
    /// would be a binding the surface parses and rejects, which reads in a log as the surface refusing
    /// a real action rather than as this side never having had one.
    private func perform(_ action: TerminalSearchSurfaceAction) {
        guard let wire = action.wire else { return }
        model?.performSearchSurfaceAction(wire)
    }
}
