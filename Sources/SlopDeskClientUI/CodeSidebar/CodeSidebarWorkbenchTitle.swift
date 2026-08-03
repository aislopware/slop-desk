// CodeSidebarWorkbenchTitle — reading the embedded workbench's document title as a readout.
//
// The panel's strip used to say only "Files", while the workbench itself knew perfectly well which
// file was open and whether it had unsaved changes: seed v14 pins
// `window.title` to `${dirty}${activeEditorShort}${separator}${rootName}`, and WebKit surfaces that
// string on `WKWebView.title` (KVO-observable). So the readout costs one observation and this
// parser — no injected JavaScript, no bridge, no polling.
//
// The two constants below are VS Code's, decoded from the shipped 4.112 workbench bundle rather
// than assumed. Pure — pinned by `CodeSidebarWorkbenchTitleTests`.

import Foundation

/// What the strip renders about the workbench's active editor.
struct CodeSidebarActiveEditor: Equatable {
    /// The file's short name (`activeEditorShort` — the basename VS Code puts in its tab).
    let name: String
    /// Whether the editor has unsaved changes (VS Code's `${dirty}` marker was present).
    let dirty: Bool
}

enum CodeSidebarWorkbenchTitle {
    /// VS Code's `${dirty}` expansion — U+25CF plus a space.
    static let dirtyMarker = "\u{25CF} "

    /// VS Code's `${separator}` default. The em-dash form is the one a macOS browser gets; the
    /// hyphen form is what every other platform gets, and it is accepted too so an iOS client
    /// reading the same title later needs no second parser.
    static let separators = [" \u{2014} ", " - "]

    /// The active editor described by `title`, or `nil` when no editor is open.
    ///
    /// With the seeded template a title carries the editor ONLY when it also carries the root name
    /// after a separator — VS Code drops empty variables and collapses the separators around them,
    /// so an editor-less workbench titles itself with the bare project name. That makes the
    /// component count, not a heuristic, the test for whether a file is open.
    ///
    /// A file name containing a separator sequence would be truncated at it. Deliberate: the
    /// alternative is a greedy split that mistakes a project name for a file, and this readout is
    /// glanceable chrome rather than a source of truth.
    static func activeEditor(in title: String?) -> CodeSidebarActiveEditor? {
        guard let title else { return nil }
        for separator in separators where title.contains(separator) {
            let head = title.components(separatedBy: separator)[0]
            let dirty = head.hasPrefix(dirtyMarker)
            let name = dirty ? String(head.dropFirst(dirtyMarker.count)) : head
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : CodeSidebarActiveEditor(name: trimmed, dirty: dirty)
        }
        return nil
    }
}
