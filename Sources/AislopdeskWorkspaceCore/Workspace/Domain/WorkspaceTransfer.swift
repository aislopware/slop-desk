import Foundation

// MARK: - WorkspaceTransfer (portable export / import)

/// Encodes a workspace to a PORTABLE document (backup / share / move-to-another-machine) and decodes one
/// back, defensively. The document is a small versioned envelope around the same `Codable` `Workspace`
/// the app already persists, with two safety rules baked in:
///
/// - **The host connection is stripped on export and never adopted on import** — a shared workspace must
///   not leak (or silently graft on) someone's `host:port`. The importer keeps its OWN connection.
/// - **A hostile / foreign / future file decodes to `nil`, never a crash** — wrong magic, unsupported
///   format version, mismatched schema, or garbage JSON all return `nil` so the live workspace is left
///   untouched.
///
/// Pure + table-tested. The id re-minting that keeps an import from colliding with the live registry is
/// the store's job (it knows the live ids); this layer only validates + repairs the shape.
public enum WorkspaceTransfer {
    /// A magic string so a random JSON file isn't mistaken for a workspace document.
    public static let magic = "aislopdesk.workspace"
    /// The document envelope version (independent of the inner ``Workspace/currentSchemaVersion``).
    public static let formatVersion = 1

    public struct Document: Codable, Sendable {
        public var format: String
        public var formatVersion: Int
        public var workspace: Workspace
        public init(format: String, formatVersion: Int, workspace: Workspace) {
            self.format = format
            self.formatVersion = formatVersion
            self.workspace = workspace
        }
    }

    /// Encodes `workspace` to a shareable document. The caller should pass an already-persistable workspace
    /// (ephemeral panes stripped); this additionally nils the host connection. Pretty-printed + key-sorted
    /// so a committed/diffed export reads cleanly.
    public static func export(_ workspace: Workspace) -> Data {
        var ws = workspace
        ws.connection = nil
        let doc = Document(format: magic, formatVersion: formatVersion, workspace: ws)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(doc)) ?? Data()
    }

    /// The largest collection sizes an imported document may carry. A shared file is untrusted input; an
    /// enormous `items` array would make the store eagerly allocate one session PER item on the main actor
    /// (UI freeze / OOM). Real workspaces are dozens of panes — this cap is far above any genuine use.
    public static let maxItems = 1024

    /// Decodes + REPAIRS `data` into a restorable workspace, or `nil` when the bytes are not a valid
    /// aislopdesk workspace document (wrong magic / unsupported format / schema mismatch / garbage / a
    /// collection beyond ``maxItems``). The host connection is dropped (the importer keeps its own);
    /// duplicate pane AND group ids are dropped/re-minted, duplicate preset names dropped, and a dangling
    /// focus / group membership normalized — a superset of the on-disk load repair, hardened against a
    /// hostile file.
    public static func decode(_ data: Data) -> Workspace? {
        guard let doc = try? JSONDecoder().decode(Document.self, from: data),
              doc.format == magic,
              doc.formatVersion <= formatVersion,
              doc.workspace.schemaVersion == Workspace.currentSchemaVersion,
              doc.workspace.canvas.items.count <= maxItems,
              doc.workspace.groups.count <= maxItems,
              doc.workspace.layoutPresets.count <= maxItems,
              doc.workspace.bookmarks.count <= maxItems else { return nil }
        var seen = Set<PaneID>()
        var ws = doc.workspace
        ws.connection = nil
        // Bookmarks live in slots 1…9 (``WorkspaceStore/saveBookmark(_:)`` rejects anything else); a
        // hand-edited document could carry junk slots that are dead weight (unreachable from the
        // ⌘1…⌘9 recall chords). Drop them so the imported map only holds reachable bookmarks.
        ws.bookmarks = ws.bookmarks.filter { (1...9).contains($0.key) }
        ws.canvas = ws.canvas.dedupingItemIDs(seen: &seen)
        // The side-collection repairs (group-id / preset-name dedup) are shared with the
        // on-disk load — see Workspace.normalizingCollections().
        return ws.normalizingCollections().normalizingFocus().normalizingGroups()
    }

    // MARK: - Tree-rooted transfer (the shipped app's live model)

    /// A magic string distinct from the canvas ``magic`` so a tree-rooted document is never mistaken for the
    /// retired v9 canvas format (and vice versa). The shipped app is ``WorkspaceStore/LiveModel/tree``, so
    /// this is the export the picker writes / reads.
    public static let treeMagic = "aislopdesk.tree-workspace"

    /// The tree-rooted document envelope (mirrors ``Document`` for the ``TreeWorkspace`` value the live app
    /// persists). Per-session host connections are stripped on export (like the canvas connection).
    public struct TreeDocument: Codable, Sendable {
        public var format: String
        public var formatVersion: Int
        public var tree: TreeWorkspace
        public init(format: String, formatVersion: Int, tree: TreeWorkspace) {
            self.format = format
            self.formatVersion = formatVersion
            self.tree = tree
        }
    }

    /// Encodes `tree` to a shareable document. Every per-session host connection is nilled (a shared
    /// workspace must not leak `host:port`). Pretty-printed + key-sorted so a committed/diffed export reads
    /// cleanly (the ``Session`` Codable already sorts its spec side table).
    public static func exportTree(_ tree: TreeWorkspace) -> Data {
        var t = tree
        t.sessions = t.sessions.map { session in
            var s = session
            s.connection = nil
            return s
        }
        let doc = TreeDocument(format: treeMagic, formatVersion: formatVersion, tree: t)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(doc)) ?? Data()
    }

    /// Decodes + REPAIRS `data` into a restorable ``TreeWorkspace``, or `nil` when the bytes are not a valid
    /// tree-rooted document (wrong magic / unsupported format / schema mismatch / garbage / a collection
    /// beyond ``maxItems``). Per-session host connections are dropped (the importer keeps its own). The id
    /// re-minting that keeps an import from colliding with the live registry is the store's job (it knows the
    /// live ids); this layer only validates + repairs the shape (``TreeWorkspace/normalized()``).
    public static func decodeTree(_ data: Data) -> TreeWorkspace? {
        guard let doc = try? JSONDecoder().decode(TreeDocument.self, from: data),
              doc.format == treeMagic,
              doc.formatVersion <= formatVersion,
              doc.tree.schemaVersion == TreeWorkspace.currentSchemaVersion,
              doc.tree.allPaneIDs().count <= maxItems,
              doc.tree.sessions.count <= maxItems,
              doc.tree.layoutPresets.count <= maxItems,
              doc.tree.launchPresets.count <= maxItems,
              doc.tree.sessionTemplates.count <= maxItems else { return nil }
        var t = doc.tree
        t.sessions = t.sessions.map { session in
            var s = session
            s.connection = nil
            return s
        }
        return t.normalized()
    }
}
