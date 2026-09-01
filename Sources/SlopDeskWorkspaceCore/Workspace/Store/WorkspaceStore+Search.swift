import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskNet
import SlopDeskTransport
import SlopDeskWorkspaceModel

// MARK: - Find-in-terminal + Global Search command entries

/// The find-in-terminal and Global Search command entries, and the receipts they publish.
public extension WorkspaceStore {
    /// The ACTIVE pane's live copy receipt, or `nil` when it has none (or is not a terminal).
    ///
    /// The seam that let the copy chip collapse to ONE mount (user-directed 2026-08-11). A pane-scoped copy
    /// publishes on its own ``TerminalViewModel/copyReceipt`` — which is right, it is the pane's state — but
    /// the CONFIRMATION used to be mounted there too, bottom-trailing inside the pane, while pane-less
    /// copies (palette "Copy Path") drew at the island's foot. One event, two homes. Reading the active
    /// pane's receipt from the island's chip stack keeps the state where it belongs and moves only the
    /// mount. ACTIVE rather than every pane on purpose: a copy is made in the pane the user is typing in,
    /// and a background pane's receipt is a cue for a place they are not looking at.
    ///
    /// A method, not a property, for the reason ``connectionAlert()`` is one: the call registers
    /// observation on the live model, so the chip appears and expires reactively.
    func activePaneCopyReceipt() -> CopyReceipt? {
        guard let active = tree.activeSession?.activeTab?.activePane else { return nil }
        return (handle(for: active) as? LivePaneSession)?.terminalModel?.copyReceipt
    }

    /// Clears the active pane's copy receipt (its chip's dwell elapsed). Idempotent, and a no-op for a
    /// non-terminal / receipt-less pane.
    func clearActivePaneCopyReceipt() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        (handle(for: active) as? LivePaneSession)?.terminalModel?.clearCopyReceipt()
    }

    /// Advances the active pane's find bar to the NEXT match (the ⌘G keyboard / menu entry).
    /// Routes to the active terminal's ``TerminalViewModel/onRequestFindNext``; when that is unset (the bar
    /// has never been opened) it FALLS BACK to ``onRequestFind`` so ⌘G OPENS the find bar — faithful
    /// "find next opens find". A no-op for a non-terminal active pane / empty shell.
    func requestFindNextInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (handle(for: active) as? LivePaneSession)?.terminalModel else { return }
        if let next = model.onRequestFindNext { next() } else { model.onRequestFind?() }
    }

    /// Steps the active pane's find bar to the PREVIOUS match (the ⇧⌘G entry). Same
    /// open-if-closed fallback as ``requestFindNextInActivePane()``.
    func requestFindPrevInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (handle(for: active) as? LivePaneSession)?.terminalModel else { return }
        if let prev = model.onRequestFindPrev { prev() } else { model.onRequestFind?() }
    }

    /// Runs `query` across EVERY live terminal pane's scrollback (session → tab → pane order),
    /// building the grouped results the ⇧⌘F surface renders. Snapshots each live terminal pane's
    /// ``TerminalViewModel/searchScrollbackLines()`` into a ``GlobalSearchSource`` (group title = the pane's
    /// spec title, falling back to its last-known shell title, else "Tab"), then delegates the match math to
    /// the PURE ``GlobalSearchController/run(sources:query:caseSensitive:isRegex:)`` — the SAME engine the
    /// in-pane find bar uses, never a second matcher. Non-terminal (video) and never-connected panes
    /// contribute no lines and so are simply absent.
    func runGlobalSearch(query: String, caseSensitive: Bool, isRegex: Bool) {
        globalSearchQuery = query
        globalSearchCaseSensitive = caseSensitive
        globalSearchRegex = isRegex
        // Re-run only the IN-MEMORY match pass over the per-overlay scrollback snapshot (gathered ONCE on
        // open by ``beginGlobalSearchSession()``), so a keystroke does not re-mirror every pane's scrollback
        // across the libghostty-vt seam. Fall back to a fresh snapshot when no overlay session is active
        // (defensive — e.g. a direct call from a test or the seed path before begin); the results are
        // identical either way.
        let sources = globalSearchSourceCache ?? collectGlobalSearchSources()
        globalSearch = GlobalSearchController.run(
            sources: sources, query: query, caseSensitive: caseSensitive, isRegex: isRegex,
        )
    }

    /// Snapshot every live terminal pane's scrollback into searchable sources ONCE and cache them for
    /// the open ⇧⌘F overlay. Called on overlay-OPEN (a re-open re-snapshots fresh scrollback); keystrokes then
    /// re-run only the in-memory match pass over this cache via ``runGlobalSearch(query:caseSensitive:isRegex:)``.
    func beginGlobalSearchSession() {
        globalSearchSourceCache = collectGlobalSearchSources()
    }

    /// Drop the cached scrollback sources when the overlay CLOSES so the next open re-snapshots fresh
    /// scrollback (and the mirrored buffers don't outlive the overlay).
    func endGlobalSearchSession() {
        globalSearchSourceCache = nil
    }

    /// Crosses the libghostty-vt seam to mirror EVERY live terminal pane's scrollback (session → tab → pane order)
    /// into a ``GlobalSearchSource`` (group title = the pane's spec title, else its last-known shell title, else
    /// "Tab"). The ONLY cross-seam step in Global Search; ``runGlobalSearch`` caches its result per overlay-open
    /// so keystrokes don't repeat it. Non-terminal (video) and never-connected panes contribute no lines and so
    /// are simply absent. Resolves the model through the ``TerminalModelProviding`` seam
    /// (not an `as? LivePaneSession` cast) so it stays headlessly testable with a recording double.
    private func collectGlobalSearchSources() -> [GlobalSearchSource] {
        var sources: [GlobalSearchSource] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for paneID in tab.allPaneIDs() {
                    guard let spec = session.spec(for: paneID), spec.kind == .terminal,
                          let model = (handle(for: paneID) as? TerminalModelProviding)?.terminalModel else { continue }
                    let title = spec.title.isEmpty ? (liveProgramTitle(for: paneID) ?? "Tab") : spec.title
                    sources.append(GlobalSearchSource(
                        paneID: paneID,
                        sessionID: session.id,
                        tabID: tab.id,
                        groupTitle: title,
                        lines: model.searchScrollbackLines().text,
                    ))
                }
            }
        }
        return sources
    }

    /// Jumps to a Global Search hit — selects its session, its tab, and focuses its pane
    /// (``focusPaneTree(_:)`` resolves session+tab+pane together), then RE-ARMS the pane's in-surface
    /// libghostty-vt search near the hit so the amber highlight + scroll-to-match land on the result.
    /// A no-op if the pane is gone.
    func jumpToGlobalSearchResult(_ hit: GlobalSearchHit) {
        guard tree.contains(hit.paneID) else { return }
        jumpToPaneTree(hit.paneID) // selects hit.sessionID + hit.tabID + focuses hit.paneID (+ breadcrumb)
        guard let model = (handle(for: hit.paneID) as? TerminalModelProviding)?.terminalModel else { return }
        // Arm the REAL query on the surface, in whatever mode the overlay was searching. It paints the
        // amber highlight and counts the hits; the tracked flags go with it, which is what closed the
        // old ceiling — the surface used to take a needle alone, so only literal + case-INSENSITIVE
        // could be armed faithfully and the other two modes landed with no highlight at all. Global
        // search has no `ab` pill, so whole-word is off by construction.
        // Nothing armed ⇒ nothing to arm: a cleared overlay must not reach into the pane and drop the
        // highlight its OWN ⌘F bar put there, which an empty needle through this door would do.
        guard !globalSearchQuery.isEmpty else { return }
        _ = model.findInSurface(
            globalSearchQuery,
            caseSensitive: globalSearchCaseSensitive,
            wholeWord: false,
            isRegex: globalSearchRegex,
        )
        // Then land on the CLICKED hit rather than on the nearest one the arm happened to select: the
        // arm scrolls to the first hit below the viewport, which is a different row whenever the user
        // clicked further down the list.
        if let scroll = GlobalSearchController.scrollAction(
            for: hit,
            query: globalSearchQuery,
            // The mirror the row is read OFF: it collapses soft-wrapped rows, so a heavily-wrapped pane
            // would otherwise land rows too high — and each entry carries the screen row the engine put it on.
            lines: model.searchScrollbackLines(),
        ) {
            model.performSearchSurfaceAction(scroll)
        }
    }

    /// Closes the active pane through the busy-shell guard: an idle pane closes immediately,
    /// a pane mid-command parks behind the `pendingClose` confirmation — and so does its project's
    /// LAST pane (closing it closes the project; the dialog warns first, mirroring
    /// ``requestClosePaneTree(_:)``). No-op without an active pane.
    func requestCloseActivePaneTree() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        if closeConfirmationNeeded(scope: .pane, pane: active) || projectClosed(byRemoving: [active]) != nil {
            parkPaneClose(active)
        } else {
            closePaneTree(active)
        }
    }

    /// Breaks the active pane out into a new tab (the "break pane to tab" command entry).
    /// No-op without an active pane.
    func breakActivePaneToTab() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        breakPaneToTab(active)
    }

    /// Toggles render-only zoom on the active pane (the "zoom/maximize" command entry).
    func toggleZoomActivePane() { toggleZoomTree() }
}
