// RemoteFileTreeView — the Details Panel's Files tab (E4, WI-5).
//
// Ports the otty file-panel (spec/user-interface__details-panel.md §"Files Tab"): a top "Find" field over a
// LAZY directory tree rooted at the pane's working directory, with disclosure triangles that fetch a
// directory's children on first expand (the host `listDirectory` verb, one level per request — the model
// caches each level so a re-expand is instant). The "Find" field filters the ALREADY-FETCHED subtree
// CLIENT-SIDE (no host round-trip), via the same vendored fzf `FuzzyMatcher` the command palette uses.
//
// The tree is plain-text rows with a leading triangle (no file-type icons — matching the otty screenshot).
// The flatten + filter + sort logic (`RemoteFileTree`) is PURE + headlessly unit-tested; the view just
// renders the resulting flat row list and dispatches expand/collapse + copy-path. Files are REMOTE host
// paths — "Copy Path" (the remote-FS-safe equivalent of otty's Reveal/Open actions) is the row action;
// Reveal-in-Finder / Open-in-app are deferred (see the E4 mapping notes).

#if canImport(SwiftUI)
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct RemoteFileTreeView: View {
    let model: PaneMetadataModel

    @State private var query = ""

    /// The visible, ordered, filtered flat row list (pure projection of the model's lazy tree state).
    private var rows: [FileTreeRow] {
        RemoteFileTree.flatten(
            root: model.rootEntries,
            children: model.childrenByPath,
            expanded: model.expandedPaths,
            query: query,
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            findField
            Rectangle().fill(Otty.Line.divider).frame(height: 1)
            treeBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(.system(size: Otty.Typeface.base))
    }

    // MARK: Find field

    private var findField: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.icon)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.base))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.icon)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.icon)
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
            .help("Refresh")
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
    }

    // MARK: Tree

    @ViewBuilder private var treeBody: some View {
        if model.rootEntries.isEmpty {
            ContentUnavailableView(
                "No Files",
                systemImage: "folder",
                description: Text(model.isConnected ? "The working-directory tree will appear here"
                    : "Connect a pane to browse its files"),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
    }

    private func rowView(_ row: FileTreeRow) -> some View {
        Button {
            if row.isDir {
                Task { await model.toggleExpand(path: row.path) }
            } else {
                copyPath(row)
            }
        } label: {
            HStack(spacing: Otty.Metric.space1) {
                if row.isDir {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: Otty.Typeface.small, weight: .semibold))
                        .foregroundStyle(Otty.Text.icon)
                        .frame(width: 10, alignment: .center)
                } else {
                    Color.clear.frame(width: 10)
                }
                Text(row.name)
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, Otty.Metric.space3 + CGFloat(row.depth) * 14)
            .padding(.trailing, Otty.Metric.space3)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                copyPath(row)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: Behaviour

    /// Copies the REMOTE host path of a row (the pane cwd joined with the row's repo-relative path) — the
    /// remote-FS-safe stand-in for otty's local Reveal/Open actions.
    private func copyPath(_ row: FileTreeRow) {
        let base = model.cwd ?? ""
        let full = base.isEmpty ? row.path : RemoteFileTree.join(base, row.path)
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = full
        #endif
    }
}

/// One flattened, render-ready file-tree row (a depth-indexed projection of the lazy directory tree).
struct FileTreeRow: Equatable, Identifiable {
    /// The repo-relative joined path (`scripts/run.sh`) — also the stable identity (unique within a tree).
    let path: String
    let name: String
    let isDir: Bool
    let depth: Int
    let isExpanded: Bool

    var id: String { path }
}

/// Pure file-tree projection: flatten the model's lazy directory state (root entries + per-path fetched
/// children + the expanded set) into an ordered, depth-indexed, FILTERED row list. Directories sort first
/// (otty), names case-insensitively; the "Find" query filters the ALREADY-FETCHED subtree client-side via
/// `FuzzyMatcher` (a node survives if it OR a fetched descendant matches). Headlessly unit-tested.
enum RemoteFileTree {
    /// Joins a parent path with a leaf (empty parent ⇒ the leaf is the root-relative path).
    static func join(_ parent: String, _ leaf: String) -> String {
        parent.isEmpty ? leaf : parent + "/" + leaf
    }

    /// Whether a leaf name passes the "Find" filter (empty query ⇒ everything; else a fuzzy match).
    static func matches(_ name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return FuzzyMatcher.score(trimmed, name) != nil
    }

    /// Directories first, then case-insensitive name order (the host returns names sorted but not
    /// dirs-first; otty groups dirs above files).
    static func sorted(_ entries: [MetadataCodec.DirEntry]) -> [MetadataCodec.DirEntry] {
        entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    static func flatten(
        root: [MetadataCodec.DirEntry],
        children: [String: [MetadataCodec.DirEntry]],
        expanded: Set<String>,
        query: String,
        parentPath: String = "",
        depth: Int = 0,
    ) -> [FileTreeRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [FileTreeRow] = []
        for entry in sorted(root) {
            let path = join(parentPath, entry.name)
            let isExpanded = entry.isDir && expanded.contains(path)
            let childRows = isExpanded
                ? flatten(
                    root: children[path] ?? [],
                    children: children,
                    expanded: expanded,
                    query: query,
                    parentPath: path,
                    depth: depth + 1,
                )
                : []
            // A node survives the filter if it matches by name, OR a fetched descendant survived.
            let include = trimmed.isEmpty || matches(entry.name, query: trimmed) || !childRows.isEmpty
            guard include else { continue }
            out.append(FileTreeRow(
                path: path, name: entry.name, isDir: entry.isDir, depth: depth, isExpanded: isExpanded,
            ))
            out.append(contentsOf: childRows)
        }
        return out
    }
}
#endif
