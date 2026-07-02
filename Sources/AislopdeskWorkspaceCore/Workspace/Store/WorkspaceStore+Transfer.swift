import Foundation

// MARK: - WorkspaceStore tree-transfer (portable backup / share, tree live model)

/// The tree-rooted export/import logic (the shipped `.tree` live model). Lives in this extension rather than
/// the main class body because it touches only the module-visible seams (`tree` is `internal(set)`,
/// `reconcileTree()` is `public`, `retainedSessionIDs` is `internal(set)`), so it needs none of the main
/// body's `private` setters — keeping the (large) `WorkspaceStore` body from growing further. The canvas
/// export/import stays in the body because it mutates the `private(set) workspace`.
extension WorkspaceStore {
    /// The tree-model import (the shipped app). `.replace` swaps the WHOLE tree (backup-restore); `.mergeAppend`
    /// adds the document's sessions beside the current ones. In BOTH modes every imported identity is
    /// re-minted (so a re-import into the running session can't collide the live registry) and the local host
    /// is KEPT (imported per-session connections were already stripped on decode). Returns whether the bytes
    /// were a valid tree document; a hostile / foreign / future file leaves the live tree untouched → `false`.
    @discardableResult
    func importTreeWorkspace(_ data: Data, mode: WorkspaceImportMode) -> Bool {
        guard let imported = WorkspaceTransfer.decodeTree(data)?.withFreshIdentities() else { return false }
        switch mode {
        case .replace:
            tree = imported.normalized()
            // A whole-workspace swap orphans the retention LRU (it points at the OLD session ids); reconcile
            // re-seeds it from the now-active session.
            retainedSessionIDs = []
        case .mergeAppend:
            // The MERGED tree must obey the same caps the on-disk load()/decode enforce, else this session
            // works but the next launch's load() discards the ENTIRE workspace back to the default (surprise
            // total data loss). Reject symmetrically; the live tree is left untouched.
            guard tree.allPaneIDs().count + imported.allPaneIDs().count <= WorkspaceTransfer.maxItems,
                  tree.sessions.count + imported.sessions.count <= WorkspaceTransfer.maxItems,
                  tree.layoutPresets.count + imported.layoutPresets.count <= WorkspaceTransfer.maxItems
            else {
                return false
            }
            var next = tree
            next.sessions += imported.sessions // focus stays on the current session (a merge shouldn't yank it)
            // Union presets by name, CONTENT-deduped first so re-merging the SAME document N times
            // can't grow the library (mirrors the canvas merge).
            for p in imported.layoutPresets
                where !next.layoutPresets.contains(where: { $0.canvas == p.canvas && $0.groups == p.groups })
            {
                let name = Self.uniqueName(base: p.name, existing: Set(next.layoutPresets.map(\.name)))
                next.layoutPresets.append(LayoutPreset(
                    name: name, canvas: p.canvas, groups: p.groups, focusedPane: p.focusedPane, triggerAppName: nil,
                ))
            }
            tree = next.normalized()
        }
        reconcileTree()
        return true
    }
}
