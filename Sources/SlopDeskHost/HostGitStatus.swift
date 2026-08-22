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
///
/// ## Why the buffer is GUESSED and not asked for
/// This door is the most expensive one in the archive: behind it is `libgit2` opening the
/// repository and walking the whole worktree. Asking `(NULL, 0)` for the length first — `docs/55`
/// §4's supported shape, and what this file did until 2026-08-22 — runs that walk to completion,
/// encodes the answer and throws it away, so every status cost TWO walks. Measured against the
/// shipped `macos-arm64` slice on this repository, `swiftc -O`, two runs agreeing: **53.4 ms and
/// 57.7 ms probe-then-fill against 25.7 ms and 27.0 ms guess-then-retry** — exactly the 2× the
/// shape predicts, on a call that runs per debounced FSEvents tick per watched repo
/// (``RepoStatusWatcher``) and per client metadata request.
///
/// ``firstGuess`` is the reference shape's "generous by an order of magnitude" (`docs/55` §6): a
/// repository's whole answer is a branch, a remote, a root and one record per changed path, and the
/// measured answer for this repository is 138 bytes. 64 KiB covers roughly a thousand changed
/// paths; past that the retry runs and costs exactly what the probe used to cost unconditionally,
/// so there is no input for which this is slower.
enum HostGitStatus {
    /// The first buffer offered to the door, sized so the retry below exists to be correct rather
    /// than to be used. `slopdesk_git::MAX_FILES` caps the record count at 4096, so a mid-rebase
    /// monster still terminates in one retry.
    private static let firstGuess = 64 * 1024

    /// The status of `cwd`'s repository, or `.noRepo`.
    static func of(cwd: String) -> MetadataCodec.GitStatusPayload {
        let bytes = Array(cwd.utf8)
        let payload: [UInt8] = bytes.withUnsafeBufferPointer { input -> [UInt8] in
            var room = [UInt8](repeating: 0, count: firstGuess)
            var needed = room.withUnsafeMutableBufferPointer { out in
                slopdesk_git_status(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            if needed > room.count {
                room = [UInt8](repeating: 0, count: needed)
                needed = room.withUnsafeMutableBufferPointer { out in
                    slopdesk_git_status(input.baseAddress, input.count, out.baseAddress, out.count)
                }
            }
            guard needed > 0, needed <= room.count else { return [] }
            room.removeLast(room.count - needed)
            return room
        }
        guard let status = try? MetadataCodec.decodeGitStatus(Data(payload)) else { return .noRepo }
        return status
    }
}
