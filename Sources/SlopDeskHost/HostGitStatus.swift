import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// The git status of a directory, read IN PROCESS.
///
/// A face over `slopdesk-git`, which opens the repository once and asks libgit2 the seven questions
/// the sidebar's git line draws: is this a repository, what branch, how far from upstream, how deep
/// is the stash, where is the toplevel, what is `origin`, and which files changed.
///
/// ## What this replaced
/// Five process spawns per answer. hostd forked `slopdesk-probe`, and the probe forked `git` four
/// times inside it (`status --porcelain -b`, `remote get-url origin`, `rev-parse --show-toplevel`,
/// `stash list`) — for one struct, re-asked by ``RepoStatusWatcher`` on every debounced FSEvents
/// tick, per watched repo. Now it is one call, and the porcelain PARSING is gone with the spawns:
/// a branch header with a bracket in it, a rename arrow inside a path, a count that might not be a
/// number were each a place to be wrong about someone else's repository.
///
/// ## Why the payload arrives ENCODED
/// The door answers the metadata reply's own bytes rather than a record and an arena, because
/// ``MetadataResponseBuilder`` forwards exactly those bytes; unpacking them here would only mean
/// packing them again there. The decode below is for ``RepoStatusWatcher``, which needs the fields
/// to fold its counts — and it is the same decoder every client runs, so the host cannot come to
/// disagree with them about what it just sent.
///
/// ## The degradation
/// A path outside a repository, an unreadable repository, and a repository that vanished between
/// the open and the walk all answer ``MetadataCodec/GitStatusPayload/noRepo``. That was already the
/// answer for the first case and for a host with no probe binary at all, so nothing downstream
/// learns a new shape.
enum HostGitStatus {
    /// The status of `cwd`'s repository, or `.noRepo`.
    static func of(cwd: String) -> MetadataCodec.GitStatusPayload {
        let bytes = Array(cwd.utf8)
        let payload: [UInt8] = bytes.withUnsafeBufferPointer { input -> [UInt8] in
            let needed = slopdesk_git_status(input.baseAddress, input.count, nil, 0)
            guard needed > 0 else { return [] }
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_git_status(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            guard written == needed else { return [] }
            return room
        }
        guard let status = try? MetadataCodec.decodeGitStatus(Data(payload)) else { return .noRepo }
        return status
    }
}
