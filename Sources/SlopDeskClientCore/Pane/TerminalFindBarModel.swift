// TerminalFindBarModel — the in-pane ⌘F find bar's DRIVER: what the user typed and which toggles are
// lit, plus a weak pane ``TerminalViewModel`` ref that carries all of it to the terminal surface. No
// view, no framework — which is why it is here rather than beside the bar that draws it (docs/56 §3: a
// UI target holds views only).
//
// Its own header always said the reason: "the GUI and the headless unit test drive the exact same
// logic". That was true of the model and false of its address — it sat in `SlopDeskClientUI` and
// imported SwiftUI for exactly one symbol, `@Observable`, which is the `Observation` module and
// reachable from every floor. So the phone's find bar and the Mac's would each have had to hold their
// own, which is the duplicate `CLAUDE.md` bans by name.
//
// ⚠️ THIS FILE USED TO HOLD A SECOND SEARCH ENGINE, and that was gap 4. The surface's own matcher
// took a needle and nothing else, so `Aa`, `ab` and `.*` had no way to reach it; the bar met them by
// scanning a flat text mirror of the same scrollback itself, counting hits there, and driving the
// viewport with `scroll_to_row:` per step. Two scans of one buffer, in two coordinate spaces: the
// `N of M` the bar printed and the cells the surface lit were two answers to one question, and in
// whole-word or case-sensitive mode they were routinely different answers. `slopdesk_term_surface_find`
// carries all four modes now, so the bar HOLDS no matches, no mirror and no index — it asks, and the
// count and the `3 of 17` are pulled back from the one engine that also painted the highlight. What is
// left here is exactly the bar's own state: the query text, three toggles, the direction it opened in,
// and the `@Observable` lifetime around them. See `docs/ui-shell/current-state/terminal-features.md`
// gap 4 and `docs/68` §5.5.
//
// Hang-safety: NO `TerminalSurface` / VideoToolbox / Metal is touched here — the model only calls the
// terminal seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a
// headless surface. That degradation is why every count here reads `0` under a headless conformer
// rather than reading a stale one: there is nothing left on this side to be stale.
//
// WHERE THE RULES LIVE. The decisions this file does not make are `slopdesk_workspace::find_bar`'s and
// reached through doors: the binding-action SPELLINGS, what a keystroke arms, the `N of M` wording, and
// vi's `n`/`N` against the direction the bar opened in.

import Observation
import SlopDeskWorkspaceCore

// MARK: - The driver

/// The find bar's view-model: the query and its three toggles + a weak pane ``TerminalViewModel`` ref
/// (the surface's four-mode search). `@Observable` so the bar re-renders on every query / toggle /
/// nav; held as `@State` by the leaf that mounts the bar, wired to the pane's `onRequestFind` /
/// `onRequestFindNext` / `onRequestFindPrev`. Weak model ref so a torn-down pane isn't kept alive by
/// the bar (the leaf is `.id(PaneID)`-keyed — an identity hazard).
@MainActor
@Observable
package final class TerminalFindBarModel {
    /// Whether the bar is shown over its pane (the leaf's top-trailing overlay gate).
    package var visible = false
    /// What the user has typed. `private(set)`: ``setQuery(_:)`` is the one way in, because every
    /// edit must reach the surface in the same breath.
    package private(set) var query = ""
    /// `Aa` — whether case must match.
    package private(set) var caseSensitive = false
    /// `.*` — whether the query is a pattern (the `regex` crate's dialect: linear-time, no lookaround).
    package private(set) var isRegex = false
    /// `ab` (underlined) — whether a hit must be bounded by non-word characters.
    package private(set) var wholeWord = false
    /// How many hits the last search found, as the SURFACE counted them.
    ///
    /// Pulled rather than computed: the number the bar prints and the number of cells lit have to be
    /// the same number, and the only way to be sure of that is for there to be one.
    package private(set) var matchCount = 0
    /// The current hit as the one-based `(current, total)` the counter prints, or `nil` when nothing
    /// is current — an empty query, or a query with no hits.
    package private(set) var positionLabel: (current: Int, total: Int)?
    /// Bumped on every (re)open so the view re-asserts its focus even when the bar is already mounted
    /// (⌘F while the bar is open should re-focus the field, but an appear hook won't fire again).
    package private(set) var focusToken = 0
    /// The SEARCH DIRECTION the bar opened in: `/` and ⌘F search FORWARD (`false`); a
    /// copy-mode `?` opens BACKWARD (`true`, via ``open(backward:)``). Biases vi's `n`/`N`: ``next()`` (`n`)
    /// steps in this direction, ``previous()`` (`N`) against it — so after `?foo`, `n` walks UP and `N` down
    /// (vim parity); a forward search keeps the natural sense.
    package private(set) var searchBackward = false
    /// The pane's terminal model — the surface's four-mode search. Weak (owned by the live session);
    /// `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private weak var model: TerminalViewModel?

    /// "search all tabs" escalation — the `rectangle.stack` button (`find.png`). Opens cross-tab Global
    /// Search (⇧⌘F) seeded with the live query. Wired by the leaf to
    /// ``OverlayCoordinator/openGlobalSearch(seed:)``; `nil` in previews / tests ⇒ the button still dismisses
    /// the bar but the escalation no-ops. Pure wiring, so `@ObservationIgnored`.
    @ObservationIgnored package var onSearchAllTabs: ((String) -> Void)?

    package init() {}

    /// Bind (or unbind, with `nil`) the pane's terminal model. The leaf calls this when it wires /
    /// clears the `onRequestFind*` callbacks (per-pane, so a torn-down leaf can't drive a dead model).
    package func attach(_ model: TerminalViewModel?) { self.model = model }

    /// ⌘F / Find… — open (or re-focus) the bar and re-run the query against the live buffer. `backward`
    /// seeds the SEARCH DIRECTION (default forward; a copy-mode `?` passes `true`) so `n`/`N` step relative to
    /// it — see ``searchBackward`` / ``next()`` / ``previous()``.
    ///
    /// The re-run on open is not redundant: the shell has printed since the bar last closed, so the
    /// hits from then are hits in a buffer that has scrolled.
    package func open(backward: Bool = false) {
        searchBackward = backward
        armSearch()
        visible = true
        focusToken &+= 1
    }

    /// Live query edit — re-run it on the surface, which recounts and repaints in one call.
    package func setQuery(_ text: String) {
        query = text
        armSearch()
    }

    /// `Aa` — flip case sensitivity and re-run.
    package func toggleCaseSensitive() {
        caseSensitive.toggle()
        armSearch()
    }

    /// `.*` — flip regex mode and re-run. A pattern that does not compile finds nothing, which is the
    /// state every unfinished `(foo` is in on the way to a real one.
    package func toggleRegex() {
        isRegex.toggle()
        armSearch()
    }

    /// `ab` (underlined) — flip whole-word matching and re-run.
    package func toggleWholeWord() {
        wholeWord.toggle()
        armSearch()
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

    /// Step one match `forward` (down) or backward (up).
    ///
    /// The surface owns the cursor, the wrap at either end, the highlight and the scroll; this side
    /// asks it to move and then reads where it landed. The read is unconditional because a step that
    /// answered `false` — no hits to move between — must still leave the counter telling the truth.
    private func step(forward: Bool) {
        perform(.navigate(forward: forward))
        readPosition()
    }

    /// `rectangle.stack` "search all tabs" — escalate the in-pane find to cross-tab Global Search (`⇧⌘F`),
    /// SEEDED with the current query, then dismiss this bar. The seed is read BEFORE ``close()`` clears it
    /// (the closure captures by value), so Global Search opens pre-filled with the live query.
    package func searchAllTabs() {
        onSearchAllTabs?(query)
        close()
    }

    /// × / Esc / search-all-tabs — clear the query, end the surface's search (drops every highlight),
    /// hide the bar, and RETURN keyboard first responder to the terminal surface.
    ///
    /// The focus hand-back is load-bearing: closing tears down the focused query field's backing view, but the
    /// pane's workspace focus never changed while the bar was open, so none of the surface's own reclaim paths
    /// (`isFocusedPane` didSet, mount, mouseDown, focus-follows-mouse — all gated on a focus TRANSITION or a
    /// click) fire. Without ``TerminalViewModel/reclaimKeyboardFocus()`` the window stays first responder and
    /// typing goes nowhere until the pane is clicked. Funnels all three close paths (Esc, ×, search-all-tabs).
    package func close() {
        query = ""
        matchCount = 0
        positionLabel = nil
        perform(.end)
        visible = false
        model?.reclaimKeyboardFocus()
    }

    /// Run the query on the surface, or end the search when there is nothing to run.
    ///
    /// One call does the counting, the highlighting and the scroll to the first hit from the viewport
    /// down, because they are one scan. The empty-query arm is the only decision left on this side and
    /// it is not made here either — `slopdesk_workspace::find_bar::Arming` has it, so the phone's bar
    /// and the Mac's cannot answer it differently.
    private func armSearch() {
        switch TerminalSearchSurfaceAction.arming(queryEmpty: query.isEmpty) {
        case .search:
            matchCount = model?.findInSurface(
                query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex,
            ) ?? 0
            readPosition()
        case .end:
            perform(.end)
            matchCount = 0
            positionLabel = nil
        }
    }

    /// Pull the surface's `3 of 17` back into the counter.
    private func readPosition() {
        positionLabel = model?.surfaceFindPosition()
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
