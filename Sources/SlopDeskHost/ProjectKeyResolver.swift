import Foundation

/// Host-side derivation of the By-Project sidebar key (wire type 34): the nearest ancestor of a
/// pane's cwd (the cwd itself included) that is a git worktree TOPLEVEL, else the cwd verbatim.
///
/// A PURE upward filesystem walk — deliberately NOT `git rev-parse --show-toplevel`: the derivation
/// runs on the PTY read-loop thread at prompt edges (``MuxChannelSession/deriveProjectKeyMessages``),
/// where a subprocess is out of the question; a `.git` existence check per ancestor is a handful of
/// `stat(2)` calls, bounded by the path depth. `.git` may be a DIRECTORY (an ordinary repo root) or a
/// FILE (a linked `git worktree` / submodule root) — `fileExists` covers both, so a linked worktree
/// groups under its own checkout root (each worktree is its own project section, matching what
/// `git rev-parse --show-toplevel` reports there).
///
/// The decision logic is pure and injectable (`isRepoRoot`) so unit tests pin the walk without
/// touching the disk; production stats the real filesystem.
enum ProjectKeyResolver {
    /// The By-Project key for `cwd`. A non-absolute / garbage path (the cwd sources are the OSC-7
    /// sniff and `proc_pidinfo`, both absolute in practice, but OSC-7 is shell-controlled input) is
    /// returned verbatim without walking — validate-then-drop, never a trap.
    static func projectKey(
        forCwd cwd: String,
        isRepoRoot: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") },
    ) -> String {
        // Normalize: strip trailing slashes (keep a bare "/") so "/repo/" and "/repo" latch and
        // emit identically.
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return path }
        var probe = Substring(path)
        while probe.count > 1 {
            if isRepoRoot(String(probe)) { return String(probe) }
            guard let slash = probe.lastIndex(of: "/") else { return path }
            // Parent directory; the top-level parent ("/x" → "") becomes "/" via max(..., 1 char).
            probe = slash == probe.startIndex ? probe[...probe.startIndex] : probe[..<slash]
        }
        // Reached "/" (or started there): "/" as a repo root is nonsensical for grouping — fall
        // back to the normalized cwd so such a pane still gets a stable, honest key.
        return path
    }
}
