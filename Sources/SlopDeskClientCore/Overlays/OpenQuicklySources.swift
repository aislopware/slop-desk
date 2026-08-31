// OpenQuicklySources — the ⌘⇧O picker's five corpora, assembled once.
//
// ``OpenQuicklyPresentation``'s header says the sources "were already below the view before this file
// existed", and that was true of the BUILDERS (``OpenQuicklyModel``) and false of the assembly. What
// each half actually held was the same ~35 lines twice: the `paneFacts` closure — including the
// `RailStructureKey.titledByProcess` guard and the argument for why it is guarded — and the
// five-entry dictionary handed to ``OpenQuicklyModel/sectioned(sources:filter:query:)``. The phone's
// own comment admitted it: *"Guarded exactly as the Mac's twin"*. Neither block named a view type.
//
// What did NOT move is the CACHING, and that is deliberate. The Mac holds its selectable rows from
// the last draw because re-deriving them costs a walk of every session, tab and pane plus a re-rank
// of the whole folder frecency history; the phone recomputes. That is a per-half performance shape
// over the same corpus, not a second answer to what the corpus IS — and the Mac's own note at its
// `selectableRows` is the record of why it is the right one.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The picker's corpora, and the sectioned list over them.
@MainActor
package enum OpenQuicklySources {
    /// The two per-pane facts the pure builders need and the tree does not carry — read from the
    /// workspace mirror, so ``OpenQuicklyModel`` stays a pure value function.
    ///
    /// The process rung is read under the SAME guard the window title uses
    /// (``WorkspaceChromePolicy/windowTitle(for:)``): reading it unconditionally would title a pane by
    /// its program where its cwd or its rename already answers, which is ``RailStructureKey``'s own
    /// escape order and not a picker's to restate — twice, least of all.
    package static func paneFacts(
        store: WorkspaceStore,
    ) -> (PaneID) -> (title: String?, cwd: String?, process: String?) {
        { [store] paneID in
            let cwd = store.paneCwd(for: paneID)
            let spec = store.tree.spec(for: paneID)
            let titled = RailStructureKey.titledByProcess(kind: spec?.kind ?? .terminal, spec: spec, cwd: cwd)
            return (
                store.liveProgramTitle(for: paneID), cwd,
                titled ? store.paneForegroundProcess[paneID] : nil,
            )
        }
    }

    /// The five source rows, keyed by the pill that shows them. `agents` and `current` arrive already
    /// built because each is fetched asynchronously by the half that owns its lifetime.
    package static func corpora(
        store: WorkspaceStore,
        folders: FolderFrecencyStore?,
        agents: [OpenQuicklyItem],
        current: [JumpToItem],
    ) -> [OpenQuicklyFilter: [OpenQuicklyItem]] {
        let facts = paneFacts(store: store)
        return [
            .opened: OpenQuicklyModel.openedItems(from: store.tree, facts: facts),
            .recent: OpenQuicklyModel.recentItems(from: store.closedTabRecords, facts: facts),
            .folders: OpenQuicklyModel.folderItems(from: folders?.ranked() ?? []),
            .agents: agents,
            .current: OpenQuicklyModel.currentItems(from: current),
        ]
    }

    /// The `.current` corpus: the FOCUSED pane, snapshotted once on the way in — the link detector over
    /// its scrollback (only when link detection is on) plus its OSC-133 command index, assembled by the
    /// pure ``JumpToModel``.
    ///
    /// A ninth ~18-line block spelled twice, found by the cross-target clone rule rather than by
    /// reading: both halves ran the same detector under the same setting gate and mapped the same
    /// `BlockSummary` out of the same navigator blocks. `nil` model ⇒ no items, which is what a picker
    /// opened over a non-terminal pane should offer.
    package static func currentItems(
        model: TerminalViewModel?, cwd: String?,
    ) -> [JumpToItem] {
        guard let model else { return [] }
        let rows = model.searchScrollbackLines().text
        let links: [DetectedLink] = SettingsKey.linkDetectionEnabled
            ? TerminalLinkDetector.detect(rows: rows, cwd: cwd, schemes: SettingsKey.linkSchemePolicy)
            : []
        let blocks = model.blocks.navigatorBlocks.map { block in
            BlockSummary(
                index: block.index,
                commandText: block.commandText,
                isPrompt: false,
                firstSeen: model.blocks.firstSeen(index: block.index),
            )
        }
        return JumpToModel.items(links: links, blocks: blocks)
    }

    /// The ranked, sectioned result list for the active pill — `.all` merges every non-empty source
    /// under its own header; a specific pill is one section.
    package static func sections(
        store: WorkspaceStore,
        folders: FolderFrecencyStore?,
        agents: [OpenQuicklyItem],
        current: [JumpToItem],
        filter: OpenQuicklyFilter,
        query: String,
    ) -> [OpenQuicklySection] {
        OpenQuicklyModel.sectioned(
            sources: corpora(store: store, folders: folders, agents: agents, current: current),
            filter: filter,
            query: query,
        )
    }
}
