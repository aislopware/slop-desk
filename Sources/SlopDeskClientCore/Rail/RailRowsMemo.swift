// RailRowsMemo — the sidebar's row-model cache, memoizing `RailRowsBuilder.rows(for:)` against a
// structural fingerprint.
//
// PROBLEM: if `NavigatorColumn`'s body called `RailRowsBuilder.rows(for:)` directly, that walk would read
// every volatile per-pane store dictionary (`paneAgentStatus`, `panePendingCompletion`,
// `paneForegroundProcess`, progress, gates, read-only, `completionFlashTick`, …). Observation tracks at
// PROPERTY granularity — reading `dict[oneKey]` depends on the WHOLE dict — so ANY pane's status tick
// would invalidate the whole sidebar body: a full O(panes) row rebuild + `disambiguated()` + sectioning +
// list diff on the main thread, keystroke-adjacent.
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

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The structural fingerprint of the rail — everything `RailRowsBuilder.rows(for:)` output depends on
/// EXCEPT the volatile per-row chrome (which the row views read live). Field coverage:
///   • tab identity + order, pane identity + pre-order (row set / order / `tabNumber`),
///   • each pane's `PaneSpec` (kind, title, `userRenamed` — `PaneSpec` is `Equatable`, so any spec edit
///     misses),
///   • the pane's two mirror-held FACTS: its `pane/cwd` and its freshness-gated live shell title. They
///     are named MEMBERS, not implied by the spec: they feed the row title, the subtitle, the tooltip,
///     the search corpus and the disambiguation pass, and the spec no longer carries either. Without
///     them here the memo returns cached rows forever and the sidebar freezes on a stale title after a
///     `cd` — with no crash, no log and no compile error,
///   • the pane's By-Project key (`paneProjectKey` — the host-pushed key else cwd; sectioning input),
///   • A4 only: the foreground process of a pane that would TITLE itself by it (no folder name, or AT
///     its project root — the at-root rung; never a user rename). Read conditionally so the whole-dict
///     Observation dependency on `paneForegroundProcess` is registered only while such a pane exists —
///     for a strayed folder-titled pane a process tick stays a cache hit.
/// Deliberately EXCLUDED (stale-safe, row views read them live): agent status, badges, completion,
/// progress, the PROJECT git summaries (the section-header leaf reads `projectGitSummary` itself),
/// read-only, `pendingTabRename`, `activeTabIndex`/`activePane` (selection is derived in the
/// navigator, not from the cached `isSelected`), and `completionFlashTick`.
package struct RailStructureKey: Equatable {
    package struct PaneKey: Equatable {
        package let id: PaneID
        package let spec: PaneSpec?
        /// `pane/cwd` — the row's title, subtitle, tooltip and hidden search key all derive from it.
        package let cwd: String?
        /// The FRESHNESS-GATED live shell title (``WorkspaceStore/liveProgramTitle(for:)``), which is
        /// what the title chain actually reads. Never the raw `pane/liveTitle`: a stale title is
        /// precisely the bug the freshness verdict exists to end.
        package let liveTitle: String?
        package let projectKey: String?
        /// A4: the title's process fallback — populated ONLY when this pane's title would resolve from it.
        package let titleProcessFallback: String?
    }

    package struct TabKey: Equatable {
        package let id: TabID
        package let panes: [PaneKey]
    }

    package let tabs: [TabKey]

    /// The fingerprint of `store`'s rail, with the two per-pane RULES resolved in ONE crossing.
    ///
    /// The By-Project key's precedence and the title's process rung are both several rules deep, and
    /// asking them per pane meant a heap allocation per string per question — the cwd lent twice to two
    /// different doors, each answer copied out through a scratch buffer into a `String` nobody keeps.
    /// Measured on a 12-pane rail, scratch harness, `swiftc -O`: 9.9 µs the old way, 4.0 µs this way;
    /// on 48 panes, 38.7 µs against 14.0 µs. The crossings were never the cost — one is about a
    /// nanosecond — so what this buys is the MARSHALLING, per `docs/55` §4c.
    ///
    /// The volatile dictionary reads stay in Swift and stay CONDITIONAL: Observation tracks at property
    /// granularity, so `store.paneForegroundProcess[id]` is a dependency on the whole dictionary and is
    /// taken only for a pane whose title would actually move with it.
    @MainActor
    package init(store: WorkspaceStore) {
        guard let session = store.tree.activeSession else {
            tabs = []
            return
        }
        // The mirror facts first, in the drawn order, so the rail crosses once rather than per tab.
        let ordered = session.tabs.map { tab in (id: tab.id, paneIDs: tab.allPaneIDs()) }
        var strings = WsStrings()
        var facts: [(cwd: String?, liveTitle: String?)] = []
        var rows: [SlopDeskWsRailStructurePane] = []
        for (_, paneIDs) in ordered {
            for paneID in paneIDs {
                let spec = session.specs[paneID]
                let cwd = store.paneCwd(for: paneID)
                facts.append((cwd, store.liveProgramTitle(for: paneID)))
                rows.append(SlopDeskWsRailStructurePane(
                    kind: Self.kindByte(spec?.kind ?? .terminal),
                    spec_title: strings.span(spec?.title),
                    user_renamed: spec?.userRenamed == true,
                    cwd: strings.span(cwd),
                    host_project_key: strings.span(store.projectKey(for: paneID)),
                ))
            }
        }
        let resolved = Self.structure(rows: &rows, strings: strings.bytes)

        var cursor = 0
        tabs = ordered.map { id, paneIDs in
            TabKey(id: id, panes: paneIDs.map { paneID in
                let index = cursor
                cursor += 1
                return PaneKey(
                    id: paneID,
                    spec: session.specs[paneID],
                    cwd: facts[index].cwd,
                    liveTitle: facts[index].liveTitle,
                    projectKey: resolved[index].key,
                    // Project-key-aware: an AT-ROOT pane titles by its program (the at-root rung), so
                    // its process is part of the SIDEBAR's structural fingerprint too.
                    titleProcessFallback: resolved[index].titledByProcess
                        ? store.paneForegroundProcess[paneID] : nil,
                )
            })
        }
    }

    /// Whether a pane's structural title would come off its foreground PROCESS —
    /// `slopdesk_workspace::rail_title`, which is also what writes the title, so the two cannot drift.
    ///
    /// `projectKey` is the pane's ALREADY-RESOLVED By-Project key, and omitting it is not a shortcut:
    /// a surface with no section headers (``WorkspaceChromePolicy/windowTitle(for:)``, the two
    /// Open-Quickly pickers) has nowhere for the folder name to be restated, so the folder name stays
    /// the title and the at-root rung never fires there.
    ///
    /// The ONE guard deciding whether reading `store.paneForegroundProcess[id]` is even worthwhile, so
    /// every title site registers the volatile process dictionary as an Observation dependency ONLY for
    /// a pane that would actually retitle by it — a background pane's process tick otherwise
    /// re-evaluates a body that can never change as a result.
    package static func titledByProcess(
        kind: PaneKind, spec: PaneSpec?, cwd: String?, projectKey: String? = nil,
    ) -> Bool {
        var strings = WsStrings()
        let shape = SlopDeskWsRailTitleShape(
            kind: kindByte(kind),
            spec_title: strings.span(spec?.title),
            user_renamed: spec?.userRenamed == true,
            cwd: strings.span(cwd),
            project_key: strings.span(projectKey),
        )
        var blob = strings.bytes
        return blob.withUnsafeMutableBufferPointer { text in
            slopdesk_ws_rail_titles_by_process(shape, text.baseAddress, text.count)
        }
    }

    /// The whole rail's `(titledByProcess, projectKey)` pairs — exactly one per row, in the caller's
    /// order, so the walk above can index it beside the array it was built from.
    ///
    /// The delivery is self-describing per pane — a flag byte, a key-PRESENCE byte, a four-byte
    /// big-endian length, then the key — because an absent key and a blank one bucket differently and a
    /// length alone could not say which. Sized in one go at 128 bytes a pane rather than through
    /// ``wsAnswerBytes(_:)``: a rail of real paths overflows that helper's 256-byte default on the
    /// third pane, and learning so costs a second crossing AND a second allocation.
    ///
    /// A short or unreadable delivery pads with "no key, not titled by its process", which is the
    /// fingerprint the pane had before either fact was known — a MISS on the next comparison, never a
    /// stale hit.
    private static func structure(
        rows: inout [SlopDeskWsRailStructurePane], strings: [UInt8],
    ) -> [(titledByProcess: Bool, key: String?)] {
        var out = Self.walked(rows: &rows, strings: strings)
        // Pad rather than trust: a short delivery must never let row `i` wear row `j`'s key.
        while out.count < rows.count { out.append((false, nil)) }
        return out
    }

    /// The delivery itself, walked as far as it reads. Never longer than `rows`; the caller pads.
    private static func walked(
        rows: inout [SlopDeskWsRailStructurePane], strings: [UInt8],
    ) -> [(titledByProcess: Bool, key: String?)] {
        var out: [(titledByProcess: Bool, key: String?)] = []
        guard !rows.isEmpty else { return out }
        out.reserveCapacity(rows.count)

        var blob = strings
        var answer = [UInt8](repeating: 0, count: rows.count * 128)
        var written = 0
        for _ in 0..<2 {
            written = rows.withUnsafeMutableBufferPointer { list in
                blob.withUnsafeMutableBufferPointer { text in
                    answer.withUnsafeMutableBufferPointer { room in
                        slopdesk_ws_rail_structure_keys(
                            list.baseAddress, list.count, text.baseAddress, text.count,
                            room.baseAddress, room.count,
                        )
                    }
                }
            }
            if written <= answer.count { break }
            answer = [UInt8](repeating: 0, count: written)
        }
        guard written > 0, written <= answer.count else { return out }

        var cursor = 0
        while out.count < rows.count, cursor + 6 <= written {
            let titled = answer[cursor] == 1
            let present = answer[cursor + 1] == 1
            var length = 0
            for byte in answer[(cursor + 2)..<(cursor + 6)] { length = length << 8 | Int(byte) }
            cursor += 6
            guard cursor + length <= written else { break }
            // Failable on purpose: the key is the crate's own string, so bytes that are not UTF-8 are
            // a corrupt delivery, and "no key" is the reading that cannot invent a section.
            let key = present
                ? String(bytes: answer[cursor..<(cursor + length)], encoding: .utf8) : nil
            cursor += length
            out.append((titled, key))
        }
        return out
    }

    /// The pane-kind byte the two doors read — `0` terminal, `1` desktop, the wire's own tag.
    private static func kindByte(_ kind: PaneKind) -> UInt8 {
        WorkspacePaneKindTag.byte(for: kind)
    }
}

/// The cache itself: one instance lives in the navigator's `@State` (plain class, NOT `@Observable` — its
/// mutation during a body eval must not re-invalidate anything). `@MainActor` like the store it reads.
@MainActor
package final class RailRowsMemo {
    /// How many times the builder actually ran — the headless test seam for the hit/miss shape (SwiftUI
    /// render counts are not testable; "`buildCount` did not move on a volatile tick" is the proxy).
    package private(set) var buildCount = 0
    private var key: RailStructureKey?
    private var cached: [RailRow] = []

    /// `nonisolated` so a SwiftUI `@State` default value (evaluated in the view struct's nonisolated
    /// memberwise init) can create the memo; all state is touched only via the `@MainActor` method below.
    package nonisolated init() {}

    /// The rail rows for `store` — the cached snapshot when the structural fingerprint is unchanged
    /// (volatile tick ⇒ NO builder walk, NO volatile-dict read), a fresh `RailRowsBuilder.rows(for:)`
    /// otherwise. Callers rendering a row must read its volatile chrome via
    /// ``RailRowsBuilder/liveChrome(for:store:)`` — the cached copies of those fields are stale by design.
    package func rows(for store: WorkspaceStore) -> [RailRow] {
        let newKey = RailStructureKey(store: store)
        if newKey == key { return cached }
        cached = RailRowsBuilder.rows(for: store)
        key = newKey
        buildCount += 1
        return cached
    }
}
