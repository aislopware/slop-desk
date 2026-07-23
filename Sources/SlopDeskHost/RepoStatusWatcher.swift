// RepoStatusWatcher — the host's EVENT-DRIVEN git-status source (wire type 35). One FSEvents stream
// per repo TOPLEVEL that still has a live pane (refcounted across panes — N panes in one repo share
// one stream and one probe), debounced so a change burst (a build, a checkout) costs ONE `git
// status`, dirty-guarded so `.git/objects` churn whose porcelain output is unchanged never wakes a
// client. This is what keeps a BACKGROUND project's section header honest within ~a second of an
// external edit; the client's own poll cadence backs off while these pushes stay fresh.

import CoreServices
import Foundation
import SlopDeskProtocol

/// All state is CONFINED to the serial `queue` — the FSEvents callbacks land there too
/// (`FSEventStreamSetDispatchQueue`), so there is no lock: the public surface only ever dispatches.
/// Blocking work (the `.git` stat gate, the git subprocess in `computeStatus`) runs on that queue,
/// never a caller's thread — a pane's key-resolve path stays hang-safe even over a wedged mount.
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

    // Queue-confined state (never touched off `queue`).
    private var ownerRepo: [ObjectIdentifier: String] = [:]
    private var repoOwners: [String: Int] = [:]
    private var sources: [String: SourceHandle] = [:]
    private var lastPushed: [String: WireMessage.ProjectGitStatus] = [:]
    private var pendingProbe: [String: UInt64] = [:]
    private var probeGeneration: UInt64 = 0
    /// Repos with a probe subprocess in flight on `probeQueue` — re-entry guard (an event burst
    /// during a slow probe must not stack subprocesses).
    private var probing: Set<String> = []
    /// Repos whose events arrived WHILE a probe was in flight — the finished probe's output is
    /// already possibly stale, so one follow-up probe re-arms when it completes.
    private var rearmAfterProbe: Set<String> = []
    private var stopped = false

    init(
        debounce: TimeInterval = 0.75,
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

    /// A pane's By-Project key latched (spawn seed / cwd-change resolve): release the owner's prior
    /// repo (a `cd` out of a repo must not keep it watched forever) and retain the new one — the
    /// first owner of a repo creates its stream, and a NON-repo key (a plain-directory section)
    /// never creates anything.
    func noteProjectKey(_ key: String, owner: ObjectIdentifier) {
        queue.async { [self] in
            guard !stopped, ownerRepo[owner] != key else { return }
            releaseOnQueue(owner)
            guard isRepoRoot(key) else { return }
            ownerRepo[owner] = key
            repoOwners[key, default: 0] += 1
            guard repoOwners[key] == 1, sources[key] == nil else { return }
            sources[key] = makeEventSource(key, queue) { [weak self] in
                self?.scheduleProbeOnQueue(key)
            }
        }
    }

    /// A pane ended (every teardown path funnels through `MuxChannelSession.shutdown()`): release
    /// its repo; the LAST owner leaving cancels the stream and forgets the repo's push memory.
    func dropOwner(_ owner: ObjectIdentifier) {
        queue.async { [self] in
            releaseOnQueue(owner)
        }
    }

    /// Daemon stop: cancel every stream and refuse all further work.
    func shutdown() {
        queue.async { [self] in
            stopped = true
            for handle in sources.values { handle.cancel() }
            sources.removeAll()
            ownerRepo.removeAll()
            repoOwners.removeAll()
            pendingProbe.removeAll()
            lastPushed.removeAll()
        }
    }

    private func releaseOnQueue(_ owner: ObjectIdentifier) {
        guard let repo = ownerRepo.removeValue(forKey: owner) else { return }
        let remaining = (repoOwners[repo] ?? 1) - 1
        if remaining > 0 {
            repoOwners[repo] = remaining
            return
        }
        repoOwners[repo] = nil
        sources.removeValue(forKey: repo)?.cancel()
        lastPushed[repo] = nil
        pendingProbe[repo] = nil
        rearmAfterProbe.remove(repo) // an in-flight probe's completion sees `sources[repo] == nil` and drops
    }

    /// An FSEvents burst landed for `repo`: (re)arm the debounce — latest event wins, so a build's
    /// thousand events collapse to one probe `debounce` after the LAST of them.
    private func scheduleProbeOnQueue(_ repo: String) {
        guard !stopped, sources[repo] != nil else { return }
        probeGeneration += 1
        let generation = probeGeneration
        pendingProbe[repo] = generation
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.probeOnQueue(repo, ifStill: generation)
        }
    }

    private func probeOnQueue(_ repo: String, ifStill generation: UInt64) {
        guard !stopped, pendingProbe[repo] == generation, sources[repo] != nil else { return }
        pendingProbe[repo] = nil
        // Nobody attached → skip the subprocess entirely; the reconnect pull catches up later.
        guard shouldProbe?() ?? true else { return }
        // A probe already in flight: don't stack a second subprocess — remember to re-arm once it
        // returns (its output may predate this event).
        guard !probing.contains(repo) else {
            rearmAfterProbe.insert(repo)
            return
        }
        probing.insert(repo)
        // The subprocess runs OFF the control queue (see `probeQueue`) — a wedged mount must never
        // freeze refcounting / other repos' event delivery / shutdown, the exact class of hang
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
        probing.remove(repo)
        let rearm = rearmAfterProbe.remove(repo) != nil
        guard !stopped, sources[repo] != nil else { return }
        // Dirty-guard: porcelain-identical output (object-db churn, a no-op save) pushes nothing.
        if let status, lastPushed[repo] != status {
            lastPushed[repo] = status
            push?(status)
        }
        if rearm { scheduleProbeOnQueue(repo) }
    }

    // MARK: - Production closures (the seam defaults)

    /// The production probe: `HostMetadataProbe.gitStatus` run AT the repo root (fd-less — the git
    /// probes never touch the PTY), folded host-side by the shared porcelain fold. `repoRoot` is
    /// pinned to the WATCH key — the canonical toplevel the type-34 resolver latched — so the
    /// client's section lookup matches byte-for-byte.
    static func probeProjectGitStatus(root: String) -> WireMessage.ProjectGitStatus? {
        let payload = HostMetadataProbe(masterFD: -1, shellPID: -1).gitStatus(cwd: root)
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
