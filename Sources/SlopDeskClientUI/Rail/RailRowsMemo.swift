// RailRowsMemo — the sidebar's row-model cache (perf audit, Option B memoization).
//
// PROBLEM: `NavigatorColumn`'s body called `RailRowsBuilder.rows(for:)` directly. That walk reads every
// volatile per-pane store dictionary (`paneAgentStatus`, `paneGitSummary`, `panePendingCompletion`,
// `paneForegroundProcess`, progress, gates, read-only, `completionFlashTick`, …). Observation tracks at
// PROPERTY granularity — reading `dict[oneKey]` depends on the WHOLE dict — so ANY pane's status tick
// invalidated the whole sidebar body: a full O(panes) row rebuild + `disambiguated()` + sectioning + list
// diff on the main thread, keystroke-adjacent.
//
// FIX SHAPE: the body asks THIS memo for the rows. The memo compares a STRUCTURAL fingerprint
// (`RailStructureKey` — tab/pane identity + specs + project keys + the A4 title-process fallback) and
// returns the cached array on a match, WITHOUT calling the builder — so a settled body registers NO
// Observation dependency on the volatile dicts and a status tick no longer invalidates it at all. The
// VOLATILE fields the cached rows carry (badge / git line / status / lock / rename mode) are stale by
// design: each row VIEW re-reads its own pane's chrome fresh via `RailRowsBuilder.liveChrome(for:store:)`,
// so a tick re-renders one cheap leaf row body instead of rebuilding the whole model.
//
// Settling: the eval that MISSES (and the first eval ever) calls the builder and therefore registers
// volatile deps — the NEXT volatile tick re-runs the body once, hits the cache while reading only the key's
// structural inputs, and the body settles out of the volatile set. One extra cheap eval per structural
// change; zero per volatile tick thereafter.
//
// Headless (no SwiftUI import) so `RailRowsMemoTests` pins the hit/miss shape without a view.

import Foundation
import SlopDeskWorkspaceCore

/// The structural fingerprint of the rail — everything `RailRowsBuilder.rows(for:)` output depends on
/// EXCEPT the volatile per-row chrome (which the row views read live). Field coverage:
///   • tab identity + order, pane identity + pre-order (row set / order / `tabNumber`),
///   • each pane's full `PaneSpec` (kind, title + `userRenamed`, cwd, `lastKnownTitle`, `railSubtitle` —
///     the title/subtitle/cwd/disambiguation inputs; `PaneSpec` is `Equatable`, so any spec edit misses),
///   • the pane's By-Project key (`paneProjectKey` — cached git toplevel else cwd; sectioning input),
///   • A4 only: the foreground process of a pane that would TITLE itself by it (no folder name, no user
///     rename). Read conditionally so the whole-dict Observation dependency on `paneForegroundProcess` is
///     registered only while such a pane exists — for cwd-titled panes a process tick stays a cache hit.
/// Deliberately EXCLUDED (stale-safe, row views read them live): agent status, badges, completion,
/// progress, git summaries, read-only, `pendingTabRename`, `activeTabIndex`/`activePane` (selection is
/// derived in the navigator, not from the cached `isSelected`), and `completionFlashTick`.
struct RailStructureKey: Equatable {
    struct PaneKey: Equatable {
        let id: PaneID
        let spec: PaneSpec?
        let projectKey: String?
        /// A4: the title's process fallback — populated ONLY when this pane's title would resolve from it.
        let titleProcessFallback: String?
    }

    struct TabKey: Equatable {
        let id: TabID
        let panes: [PaneKey]
    }

    let tabs: [TabKey]

    @MainActor
    init(store: WorkspaceStore) {
        guard let session = store.tree.activeSession else {
            tabs = []
            return
        }
        tabs = session.tabs.map { tab in
            TabKey(id: tab.id, panes: tab.allPaneIDs().map { paneID in
                let spec = session.specs[paneID]
                let kind = spec?.kind ?? .terminal
                // Mirror `RailRowsBuilder.rowTitle`'s escape order: a terminal pane consults the
                // foreground process only when it has a spec, is NOT user-renamed, and has no cwd folder
                // name — exactly the case where a process change changes the TITLE (structural).
                let titledByProcess = kind == .terminal
                    && spec != nil
                    && !(spec?.userRenamed == true && spec?.title.isEmpty == false)
                    && RailRowsBuilder.cwdFolderName(spec?.lastKnownCwd) == nil
                return PaneKey(
                    id: paneID,
                    spec: spec,
                    projectKey: kind == .terminal ? store.paneProjectKey(paneID) : nil,
                    titleProcessFallback: titledByProcess ? store.paneForegroundProcess[paneID] : nil,
                )
            })
        }
    }
}

/// The cache itself: one instance lives in the navigator's `@State` (plain class, NOT `@Observable` — its
/// mutation during a body eval must not re-invalidate anything). `@MainActor` like the store it reads.
@MainActor
final class RailRowsMemo {
    /// How many times the builder actually ran — the headless test seam for the hit/miss shape (SwiftUI
    /// render counts are not testable; "`buildCount` did not move on a volatile tick" is the proxy).
    private(set) var buildCount = 0
    private var key: RailStructureKey?
    private var cached: [RailRow] = []

    /// `nonisolated` so a SwiftUI `@State` default value (evaluated in the view struct's nonisolated
    /// memberwise init) can create the memo; all state is touched only via the `@MainActor` method below.
    nonisolated init() {}

    /// The rail rows for `store` — the cached snapshot when the structural fingerprint is unchanged
    /// (volatile tick ⇒ NO builder walk, NO volatile-dict read), a fresh `RailRowsBuilder.rows(for:)`
    /// otherwise. Callers rendering a row must read its volatile chrome via
    /// ``RailRowsBuilder/liveChrome(for:store:)`` — the cached copies of those fields are stale by design.
    func rows(for store: WorkspaceStore) -> [RailRow] {
        let newKey = RailStructureKey(store: store)
        if newKey == key { return cached }
        cached = RailRowsBuilder.rows(for: store)
        key = newKey
        buildCount += 1
        return cached
    }
}
