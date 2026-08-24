import CSlopDeskFFI
import Foundation

/// The By-Project sidebar key (wire type 34) for a pane's cwd.
///
/// A face over `rust/slopdesk-git`'s `project_key`, which resolves the path and walks it to the
/// nearest ancestor carrying a `.git` — see that module for why the boundary is a `stat(2)` walk
/// rather than a `libgit2` discovery, and why the canonical form has to come first.
///
/// The canonicalisation used to be a second `realpath(3)` on this side, called by the one caller
/// just before the walk. One crossing now, because two spellings of "which directory are we talking
/// about" is precisely how one repository became two sidebar sections.
///
/// Blocking: hostd calls it on its `metadataQueue`, never on the PTY read loop
/// (``MuxChannelSession/scheduleProjectKeyResolve(for:)``).
enum ProjectKey {
    /// The key for `cwd`. A path that resolves to nothing is answered verbatim, so a pane always
    /// has a stable key even when its directory has gone.
    static func of(cwd: String) -> String {
        let bytes = Array(cwd.utf8)
        return bytes.withUnsafeBufferPointer { input -> String in
            // A key is an ANCESTOR of the resolved path, and resolving can lengthen a path (a
            // symlink's target is arbitrary), so the input's length is not a bound: ask, then read.
            let needed = slopdesk_project_key(input.baseAddress, input.count, nil, 0)
            guard needed > 0 else { return cwd }
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_project_key(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            guard written == needed else { return cwd }
            return String(bytes: room, encoding: .utf8) ?? cwd
        }
    }
}
