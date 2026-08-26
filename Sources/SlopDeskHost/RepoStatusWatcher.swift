// RepoStatusWatcher — the host's EVENT-DRIVEN git-status source (wire type 35). One FSEvents stream
// per repo TOPLEVEL that still has a live pane (refcounted across panes — N panes in one repo share
// one stream and one probe), debounced so a change burst (a build, a checkout) costs ONE `git
// status`, dirty-guarded so `.git/objects` churn whose porcelain output is unchanged never wakes a
// client. This is what keeps a BACKGROUND project's section header honest within ~a second of an
// external edit; the client's own poll cadence backs off while these pushes stay fresh.

import CoreServices
import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskProtocol

/// All state is CONFINED to the serial `queue` — the FSEvents callbacks land there too
/// (`FSEventStreamSetDispatchQueue`), so there is no lock: the public surface only ever dispatches.
/// Blocking work (the `.git` stat gate, the git subprocess in `computeStatus`) runs on that queue,
/// never a caller's thread — a pane's key-resolve path stays hang-safe even over a wedged mount.
///
/// What is left here is the FRAMEWORK half. Every decision — the owner refcounts, the debounce
/// generation, the one-reading-in-flight guard and its single re-arm, the dirty guard — is
/// `slopdesk_muxsession::repo_watch`, reached through the handle door in `slopdesk-ffi`. That
/// handle's "no two overlapping calls" obligation is satisfied by the same confinement the paragraph
/// above already describes: every call below is made from `queue`.
final class RepoStatusWatcher: @unchecked Sendable {
    /// One live event source's teardown (production: stop + invalidate + release of the FSEvents
    /// stream). The seam type — tests hand back a no-op handle and fire events by hand.
    struct SourceHandle {
        let cancel: () -> Void
    }

    /// The push sink (``HostServer`` routes to every attached session sectioned under the repo).
    /// A settable property (not an init param) so the owning server can capture `[weak self]`
    /// AFTER its own initialization; set once at wiring, before any source can fire.
    var push: (@Sendable (WireMessage.ProjectGitStatus) -> Void)?

    /// Probe gate: when it answers false (no client attached — nobody to tell), the debounced
    /// probe is SKIPPED entirely (no git subprocess for a wall of detached agents). Catch-up is the
    /// client's existing reconnect pull. Same settable-property shape as ``push``.
    var shouldProbe: (@Sendable () -> Bool)?

    private let queue = DispatchQueue(label: "slopdesk.host.repo-watch", qos: .utility)
    private let debounce: TimeInterval
    private let isRepoRoot: @Sendable (String) -> Bool
    private let computeStatus: @Sendable (String) -> WireMessage.ProjectGitStatus?
    private let makeEventSource: @Sendable (String, DispatchQueue, @escaping @Sendable () -> Void)
        -> SourceHandle?

    /// Where the git SUBPROCESS actually runs — concurrent, so a repo wedged on a hung NFS/SMB
    /// mount stalls only its own probe thread, never the control `queue` (refcounts, FSEvents
    /// delivery for OTHER repos, `shutdown()`) and never another repo's probe. One-probe-per-repo
    /// is enforced by `probing` on the control queue, so "concurrent" is bounded by the number of
    /// distinct live repos.
    private let probeQueue = DispatchQueue(
        label: "slopdesk.host.repo-probe", qos: .utility, attributes: .concurrent,
    )

    /// The verdict fold — every map, set and counter this class used to hold. Freed in `deinit`,
    /// which cannot run while work is queued: each `queue.async` below captures `self` strongly.
    private let rules: OpaquePointer = slopdesk_repo_watch_new()

    /// The only state left on this side: the live event streams, keyed by the repo they watch. The
    /// fold names a repo; this table turns the name back into the handle to cancel.
    private var handles: [String: SourceHandle] = [:]

    init(
        debounce: TimeInterval = slopdesk_repo_watch_debounce_seconds(),
        isRepoRoot: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0 + "/.git")
        },
        computeStatus: @escaping @Sendable (String) -> WireMessage.ProjectGitStatus? =
            RepoStatusWatcher.probeProjectGitStatus,
        makeEventSource: @escaping @Sendable (String, DispatchQueue, @escaping @Sendable () -> Void)
            -> SourceHandle? = RepoStatusWatcher.fsEventsSource,
    ) {
        self.debounce = debounce
        self.isRepoRoot = isRepoRoot
        self.computeStatus = computeStatus
        self.makeEventSource = makeEventSource
    }

    deinit { slopdesk_repo_watch_free(rules) }

    /// The fold identifies an owner by an opaque integer — see the module doc on the Rust side.
    private static func slot(_ owner: ObjectIdentifier) -> UInt64 {
        UInt64(UInt(bitPattern: owner))
    }

    /// Reads back the answer a mutating door stashed.
    ///
    /// The three doors that change the fold return their answer's size rather than taking a buffer,
    /// because the header's ask-then-grow protocol would run a mutator TWICE on a short guess — and
    /// the second run of `shutdown` hands back nothing, which is how a stream would be left alive
    /// with nobody watching it. `slopdesk_repo_watch_answer` is pure, so one exact-sized read is all
    /// this needs; it is the same split `FramePacketizer` makes for the same reason.
    private func drainAnswer(_ needed: Int) -> [UInt8] {
        guard needed > 0 else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            slopdesk_repo_watch_answer(rules, $0.baseAddress, $0.count)
        }
        return written == needed ? blob : []
    }

    /// A pane's By-Project key latched (spawn seed / cwd-change resolve): release the owner's prior
    /// repo (a `cd` out of a repo must not keep it watched forever) and retain the new one — the
    /// first owner of a repo creates its stream, and a NON-repo key (a plain-directory section)
    /// never creates anything.
    func noteProjectKey(_ key: String, owner: ObjectIdentifier) {
        let slot = Self.slot(owner)
        queue.async { [self] in
            // The `.git` test is a filesystem call, so it is asked only when the answer can matter —
            // the fold re-asks the same question itself, so skipping it changes nothing but work.
            let wants = ffiLend(key) { bytes in
                slopdesk_repo_watch_wants_key(rules, slot, bytes.baseAddress, bytes.count)
            }
            guard wants else { return }
            let isRoot = isRepoRoot(key)
            let needed = ffiLend(key) { bytes in
                slopdesk_repo_watch_note_project_key(
                    rules, slot, bytes.baseAddress, bytes.count, isRoot,
                )
            }
            let effects = ffiRuns(drainAnswer(needed), count: 2)
            guard effects.count == 2 else { return }
            if !effects[0].isEmpty { handles.removeValue(forKey: effects[0])?.cancel() }
            if !effects[1].isEmpty { startSourceOnQueue(effects[1]) }
        }
    }

    /// A pane ended (every teardown path funnels through `MuxChannelSession.shutdown()`): release
    /// its repo; the LAST owner leaving cancels the stream and forgets the repo's push memory.
    func dropOwner(_ owner: ObjectIdentifier) {
        let slot = Self.slot(owner)
        queue.async { [self] in
            let cancelled = String(
                decoding: drainAnswer(slopdesk_repo_watch_drop_owner(rules, slot)), as: UTF8.self,
            )
            if !cancelled.isEmpty { handles.removeValue(forKey: cancelled)?.cancel() }
        }
    }

    /// Daemon stop: cancel every stream and refuse all further work.
    func shutdown() {
        queue.async { [self] in
            let blob = drainAnswer(slopdesk_repo_watch_shutdown(rules))
            // A run costs at least its four-byte prefix, so this is a sound upper bound on how many
            // there can be, and `ffiRuns` stops on the first one that would read past the end.
            for repo in ffiRuns(blob, count: blob.count / 4) {
                handles.removeValue(forKey: repo)?.cancel()
            }
            handles.removeAll()
        }
    }

    /// Starts the event stream for a repo the fold just asked for one for.
    ///
    /// A stream the framework refuses to create leaves no handle, which is the honest state: the
    /// fold counts the repo as watched and simply never hears from it, so every later verdict about
    /// it is unreachable and the cancel it is eventually told to perform finds nothing.
    private func startSourceOnQueue(_ repo: String) {
        handles[repo] = makeEventSource(repo, queue) { [weak self] in
            guard let self else { return }
            // Re-dispatched rather than folded in place: the production callback already lands on
            // `queue`, but the handle door forbids two overlapping calls and a seam that fires from
            // a caller's own thread would otherwise make one.
            queue.async { [weak self] in self?.sourceEventOnQueue(repo) }
        }
    }

    /// An FSEvents burst landed for `repo`: (re)arm the debounce — latest event wins, so a build's
    /// thousand events collapse to one probe `debounce` after the LAST of them.
    private func sourceEventOnQueue(_ repo: String) {
        var generation: UInt64 = 0
        let armed = withUnsafeMutablePointer(to: &generation) { slot in
            ffiLend(repo) { bytes in
                slopdesk_repo_watch_source_event(rules, bytes.baseAddress, bytes.count, slot)
            }
        }
        if armed { armDebounceOnQueue(repo, generation: generation) }
    }

    private func armDebounceOnQueue(_ repo: String, generation: UInt64) {
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.probeOnQueue(repo, ifStill: generation)
        }
    }

    private func probeOnQueue(_ repo: String, ifStill generation: UInt64) {
        // The audience gate is read one step earlier than it used to be, because the fold decides
        // the stale/gated/deferred order and wants the answer with the question. It is a boolean the
        // server already holds; what it gates — the walk below — is unchanged.
        let audience = shouldProbe?() ?? true
        let verdict = ffiLend(repo) { bytes in
            slopdesk_repo_watch_debounce_fired(
                rules, bytes.baseAddress, bytes.count, generation, audience,
            )
        }
        guard verdict == UInt8(SLOPDESK_REPO_WATCH_PROBE) else { return }
        // The read runs OFF the control queue (see `probeQueue`) — a wedged mount must never freeze
        // refcounting / other repos' event delivery / shutdown, the exact class of hang
        // `MuxChannelSession.deriveProjectKey` dispatches away from its read loop for.
        probeQueue.async { [weak self] in
            guard let self else { return }
            let status = computeStatus(repo)
            queue.async { [weak self] in
                self?.finishProbeOnQueue(repo, status: status)
            }
        }
    }

    private func finishProbeOnQueue(_ repo: String, status: WireMessage.ProjectGitStatus?) {
        let verdict = ffiLend(repo) { repoBytes in
            ffiLend(status?.repoRoot ?? "") { rootBytes in
                ffiLend(status?.branch ?? "") { branchBytes in
                    slopdesk_repo_watch_probe_finished(
                        rules,
                        repoBytes.baseAddress, repoBytes.count,
                        status != nil,
                        rootBytes.baseAddress, rootBytes.count,
                        branchBytes.baseAddress, branchBytes.count,
                        status?.ahead ?? 0, status?.behind ?? 0, status?.stashCount ?? 0,
                        status?.staged ?? 0, status?.modified ?? 0, status?.untracked ?? 0,
                        status?.conflicted ?? 0, status?.changedCount ?? 0,
                    )
                }
            }
        }
        if verdict.push, let status { push?(status) }
        if verdict.has_rearm { armDebounceOnQueue(repo, generation: verdict.rearm) }
    }

    // MARK: - Production closures (the seam defaults)

    /// The production probe: one ``HostGitStatus`` read AT the repo root, folded host-side by the
    /// shared porcelain fold. It goes through that face directly rather than through a pane's
    /// ``HostMetadataProbe`` because there is no pane here — the fd-less `-1, -1` this used to
    /// construct was a stand-in for a PTY the git questions never touched. `repoRoot` is pinned to the
    /// WATCH key — the canonical toplevel the type-34 resolver latched — so the client's section
    /// lookup matches byte-for-byte.
    ///
    /// It is no longer a subprocess at all. Every comment below that calls this a "probe" or a
    /// "subprocess" is about the DISPATCH, which still stands: the read is a filesystem walk over
    /// someone's worktree, and a wedged mount must not be able to freeze the control queue.
    static func probeProjectGitStatus(root: String) -> WireMessage.ProjectGitStatus? {
        let payload = HostGitStatus.of(cwd: root)
        guard payload.hasRepo else { return nil }
        let counts = payload.foldedCounts
        return WireMessage.ProjectGitStatus(
            repoRoot: root,
            branch: payload.branch,
            ahead: payload.ahead,
            behind: payload.behind,
            stashCount: payload.stashCount,
            staged: UInt32(counts.staged),
            modified: UInt32(counts.modified),
            untracked: UInt32(counts.untracked),
            conflicted: UInt32(counts.conflicted),
            changedCount: UInt32(payload.files.count),
        )
    }

    /// The production event source: one recursive FSEvents stream rooted at the repo toplevel
    /// (worktree edits AND `.git` index/HEAD/ref changes both move `git status`), callbacks on
    /// `queue`, kernel-side latency 0.25 s (a first coalesce under our own debounce). The box keeps
    /// the closure alive for the stream's life; the context `release` balances `passRetained` when
    /// the stream is invalidated.
    static func fsEventsSource(
        path: String, queue: DispatchQueue, onEvent: @escaping @Sendable () -> Void,
    ) -> SourceHandle? {
        final class EventBox {
            let fire: @Sendable () -> Void
            init(fire: @escaping @Sendable () -> Void) { self.fire = fire }
        }
        let box = Unmanaged.passRetained(EventBox(fire: onEvent))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<EventBox>.fromOpaque(info).release()
            },
            copyDescription: nil,
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer),
        ) else {
            box.release() // the context release callback never runs for a stream that was never made
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream) // runs the context release → balances passRetained
            FSEventStreamRelease(stream)
            return nil
        }
        return SourceHandle {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
