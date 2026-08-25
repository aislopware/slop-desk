import Foundation

/// TTL-bounded store for detached (client-disconnected) ``MuxChannelSession`` instances.
///
/// When a client disconnects with `SLOPDESK_DETACH_ENABLED` on, the host calls
/// ``insert(_:key:ttl:)`` instead of shutting the shell down. The session lives here until
/// either (a) the client returns and calls ``claim(_:)`` to reattach, (b) the TTL fires and
/// ``evict(_:)`` kills the shell, or (c) ``drainAll()`` is called on `stop()`.
///
/// Synchronous by design: an actor would force every transition through an `await` hop, and two
/// of those hops are load-bearing races —
///
/// 1. `detach → Task { await store.insert }` — a fire-and-forget insert can lose to a fast
///    reconnect's lookup, which then misses the store and spawns a SECOND shell under the same
///    sessionID (orphaned live PTY + two writers interleaving one scrollback journal).
/// 2. a `lookup` that returns the live session WITHOUT removing it lets two concurrent reconnects
///    (or a reconnect racing an armed TTL task) both obtain the same session; the loser's later
///    `channelClose` then kills the winner's live PTY and deletes its disk journal.
///
/// As a lock-guarded class, ``insert(_:key:ttl:)`` completes before `detachMuxSession` returns
/// (no scheduling gap), and ``claim(_:)`` removes the entry + cancels its TTL task in ONE
/// critical section — exactly one caller can ever win a given sessionID. `HostServer` may call
/// these while holding its own `lock` (short dictionary ops only; nothing here calls back into
/// `HostServer`, so the nesting is one-way and deadlock-free — `shutdownDetached()` is an async
/// dispatch, never a blocking kill on the caller's thread).
final class DetachedSessionStore: @unchecked Sendable {
    struct Entry {
        let session: MuxChannelSession
        let key: MuxSessionKey
        let detachedAt: Date
        var ttlTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var store: [UUID: Entry] = [:]

    /// OPT-IN cap on concurrently-detached sessions, or `nil` for UNBOUNDED — the default and
    /// the tmux/zellij semantics (verified against both sources: neither imposes any session
    /// count limit, and neither ever silently kills a live detached session — their resource
    /// bounds are per-pane scrollback limits, which SlopDesk already has, stricter: 64 MiB ring +
    /// 64 MiB journal + 64 KiB FIFO + the offline drain gate per session; hostd raises the fd
    /// soft limit toward 8192 at start for the PTY-master + journal fds). When a cap IS set
    /// (env `SLOPDESK_DETACH_MAX_SESSIONS` > 0), the OLDEST by `detachedAt` is evicted (killed)
    /// when a new insert would exceed it. Injected so tests can drive overflow headlessly.
    let maxSessions: Int?

    /// Fired AFTER the store itself KILLS a stored session — TTL eviction (``evict(_:)``) and
    /// overflow eviction (``insert(_:key:ttl:)`` past `maxSessions`). These are the
    /// non-deliberate ends of life that never reach `HostServer.removeMuxSession`, so the
    /// server uses this hook to release the session's per-id resources (the disk-journal
    /// writer fd + the hook-sink key). Always invoked OUTSIDE the store lock, after
    /// `shutdownDetached()`. Deliberately NOT fired for:
    /// - ``claim(_:)``'s dead-child auto-evict — it runs under `HostServer.lock` (the hook
    ///   re-takes it → deadlock), and the immediately-following fresh spawn for the SAME
    ///   sessionID reuses the journal writer anyway;
    /// - the displaced same-id duplicate in ``insert(_:key:ttl:)`` — the NEW entry shares the
    ///   sessionID, so releasing would tear down the live entry's resources;
    /// - ``remove(_:)`` / ``drainAll()`` — the caller owns those paths (detached exit wires its
    ///   own cleanup; drain is daemon stop).
    /// Set once by `HostServer.init` before any session can flow. Receives the evicted SESSION
    /// (not just its id) so the handler can tear down instance-owned resources (the journal
    /// writer) without guessing whether a same-UUID successor took the id over.
    var onEvicted: (@Sendable (MuxChannelSession) -> Void)?

    init(maxSessions: Int? = nil) {
        self.maxSessions = maxSessions
    }

    // MARK: Insert

    /// Stores `session` under its `sessionID` (the UUID the client sent in the `channelOpen`)
    /// and arms a TTL eviction task. If the store is full the OLDEST entry is evicted first.
    /// IDEMPOTENT per session: re-inserting a session that is already stored keeps the
    /// original entry (detachedAt + armed TTL) — the failed-rebind re-park and
    /// `handleLinkDown` may both park the same session on a mid-reattach link drop.
    ///
    /// Synchronous: when this returns, a reconnect's ``claim(_:)`` is guaranteed to find the
    /// entry — the caller (`detachMuxSession`) must invoke it inline, never fire-and-forget.
    ///
    /// - Parameter ttl: time until the shell is automatically killed, or `nil` to keep the
    ///   detached session ALIVE INDEFINITELY — the tmux/zellij semantics and the default (env
    ///   `SLOPDESK_DETACH_TTL_SECS`, unset/`0` = never; the `maxSessions` cap is the resource
    ///   bound). Pass `.milliseconds(10)` in tests.
    func insert(_ session: MuxChannelSession, key: MuxSessionKey, ttl: Duration?) {
        let id = session.sessionID

        // OPT-IN cap enforcement: evict the oldest entry when full (no cap set = unbounded,
        // the tmux semantics — never silently kill a live detached session). The victim is
        // taken out under the lock; its kill (an async dispatch) runs after unlock.
        var overflowVictim: Entry?
        var displaced: Entry?
        lock.lock()
        // The store is a dictionary and the rule reads a LIST, so one ordering of it is taken here
        // and every answer comes back as a position into that same ordering. Nothing about a
        // session crosses: the `===` that separates an idempotent re-park from a displacement is
        // asked on this side, because only this side can ask it.
        let entries = Array(store.values)
        let occupant = entries.firstIndex { $0.session.sessionID == id }.map { position in
            (position: position, isSameSession: entries[position].session === session)
        }
        let verdict = DetachRetentionRules.insertVerdict(
            stamps: entries.map { $0.detachedAt.timeIntervalSinceReferenceDate },
            occupant: occupant,
            cap: maxSessions,
        )
        if verdict.isIdempotent {
            // The session is already stored — keep the ORIGINAL entry, its detachedAt and its armed
            // TTL task. The failed-rebind recovery can race handleLinkDown's own insert.
            lock.unlock()
            return
        }
        if verdict.displaces {
            // Same id, DIFFERENT session: newest wins, but the displaced entry's TTL task must be
            // cancelled (it would evict the NEW entry later) and its now-unreachable session
            // reaped instead of leaking.
            //
            // What keeps this shape rare is the JOIN: a live sessionID routes to the session that
            // already exists, so two connections holding one pane share ONE session object and park
            // it exactly once, when the LAST subscriber leaves. But "should be unreachable" is not
            // a licence to reap blind: the displaced session is only reaped below if NOBODY holds
            // it. A session with subscribers is live, reachable through `muxSessions`, and its life
            // belongs to whoever is on it — killing it here would take down a client's running
            // agent to make room for a store entry.
            displaced = store.removeValue(forKey: id)
        }
        if let victim = verdict.victim, entries.indices.contains(victim) {
            overflowVictim = store.removeValue(forKey: entries[victim].session.sessionID)
        }

        let ttlTask: Task<Void, Never>? = ttl.map { ttl in
            Task { [weak self] in
                do { try await Task.sleep(for: ttl) } catch { return }
                self?.evict(id)
            }
        }

        store[id] = Entry(session: session, key: key, detachedAt: Date(), ttlTask: ttlTask)
        lock.unlock()

        if let displaced {
            displaced.ttlTask?.cancel()
            // Reaped only when nothing is watching it — see the note at the removal above.
            if displaced.session.subscriberCount == 0 { displaced.session.shutdownDetached() }
        }
        if let overflowVictim {
            overflowVictim.ttlTask?.cancel()
            overflowVictim.session.shutdownDetached()
            onEvicted?(overflowVictim.session)
        }
    }

    // MARK: Claim (exclusive reattach hand-off)

    /// Atomically TAKES the live session for `sessionID` out of the store — removes the entry
    /// AND cancels its TTL task in one critical section — or returns `nil` if not found /
    /// child already exited.
    ///
    /// Exclusivity is the point: of two concurrent reconnects presenting the
    /// same sessionID, exactly ONE gets the session; the other sees `nil` and falls through to
    /// the fresh-shell path (where `HostServer`'s live-sessionID guard refuses the duplicate).
    /// Cancelling the TTL task here closes the reattach-vs-TTL race: once claimed, an armed
    /// eviction can no longer find the entry (`evict` misses) and can never kill the PTY out
    /// from under the in-flight rebind.
    ///
    /// A child-exited session is AUTO-EVICTED on claim (the zombie would be reaped by
    /// `removeMuxSession` → `shutdown` when `onExit` fires, but if the client reconnects
    /// first we want it to get a fresh shell, not hang on a dead one). Its fd cleanup uses
    /// `shutdownDetached()` (the child exited naturally — nothing to kill).
    ///
    /// The dead-child reap is REPORTED (`.reapedDeadChild`), not folded into "not found": the
    /// caller took over this entry's teardown (the session's own `onDetachedExit` closure sees
    /// ``remove(_:)`` return `false` and stands down), so the caller must finish what that
    /// closure would have done — fan the final agent-status `.none` (prevent-sleep strict
    /// balance) and drop the hook-sink key — before spawning the same-UUID fresh shell.
    enum ClaimOutcome {
        case notFound
        case claimed(MuxChannelSession)
        case reapedDeadChild(MuxChannelSession)

        /// The live claimed session, `nil` for the other outcomes (test convenience).
        var claimedSession: MuxChannelSession? {
            if case let .claimed(session) = self { session } else { nil }
        }
    }

    func claim(_ sessionID: UUID) -> ClaimOutcome {
        lock.lock()
        guard let entry = store.removeValue(forKey: sessionID) else {
            lock.unlock()
            return .notFound
        }
        entry.ttlTask?.cancel()
        lock.unlock()

        if entry.session.isChildExited() {
            entry.session.shutdownDetached()
            return .reapedDeadChild(entry.session)
        }
        return .claimed(entry.session)
    }

    // MARK: Contains

    /// Whether a detached entry exists for `sessionID`. Used by `HostServer`'s failed-rebind
    /// recovery to decide whether a refused reattach must re-park the session (`handleLinkDown`
    /// may already have). Safe while holding `HostServer.lock` (one-way nesting — see the class
    /// doc).
    func contains(_ sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store[sessionID] != nil
    }

    // MARK: Enumerate

    /// Every stored session — the detached half of the host's pane inventory.
    ///
    /// A pane whose client quit is ALIVE (that is the entire point of the store) but lived outside
    /// every enumeration the product had: `listPanesForControl` read only `muxSessions +
    /// controlSessions`, so `slopdesk-ctl list-panes` reported nothing for exactly the panes a
    /// returning user cares about. Ordered by `detachedAt` so the listing is stable rather than
    /// dictionary-ordered. Safe while holding `HostServer.lock` (one-way nesting — see the class
    /// doc).
    func allSessions() -> [MuxChannelSession] {
        lock.lock()
        defer { lock.unlock() }
        let entries = Array(store.values)
        let order = DetachRetentionRules.order(
            stamps: entries.map { $0.detachedAt.timeIntervalSinceReferenceDate },
        )
        return order.compactMap { position in
            entries.indices.contains(position) ? entries[position].session : nil
        }
    }

    // MARK: Remove (clean exit while in store)

    /// Removes the entry WITHOUT killing the shell. Called when the shell exits naturally
    /// (its `onExit` callback fires) while the session is detached — the PTY is already dead,
    /// so there's nothing to kill; we just drop the store entry (TTL task cancelled).
    ///
    /// Returns whether THIS call removed the entry — i.e. whether the caller WON the teardown.
    /// `false` means `claim()`/`evict()`/`drainAll()` already took the entry and owns the
    /// per-id resource teardown; a stale detached-exit closure firing afterwards must then
    /// stand down, or it releases the journal writer + hook sink a same-UUID SUCCESSOR session
    /// is already using (silently killing the live pane's journaling + agent-status routing).
    @discardableResult
    func remove(_ sessionID: UUID) -> Bool {
        lock.lock()
        let entry = store.removeValue(forKey: sessionID)
        lock.unlock()
        entry?.ttlTask?.cancel()
        return entry != nil
    }

    // MARK: Evict (TTL / overflow)

    /// Kills and removes the session. Called by the TTL task or the overflow eviction.
    /// A no-op when the entry was already claimed/removed — the TTL-vs-reattach race
    /// resolves in the reattach's favor.
    func evict(_ sessionID: UUID) {
        lock.lock()
        let entry = store.removeValue(forKey: sessionID)
        lock.unlock()
        guard let entry else { return }
        entry.ttlTask?.cancel()
        entry.session.shutdownDetached()
        onEvicted?(entry.session)
    }

    // MARK: drainAll

    /// Kills every stored session.
    ///
    /// No longer reached from `HostServer.stop()` — see ``relinquishAll()``. Kept for the paths
    /// that really do mean "end these panes": a store being torn down for good.
    func drainAll() {
        lock.lock()
        let entries = Array(store.values)
        store.removeAll()
        lock.unlock()
        for entry in entries {
            entry.ttlTask?.cancel()
            entry.session.shutdownDetached()
        }
    }

    /// Lets every stored session GO, without killing a single shell. `HostServer.stop()`'s path.
    ///
    /// A parked pane is, by definition, one whose client already left and whose shell the user
    /// still wants — killing exactly those on a daemon stop was the sharpest edge of the old
    /// behaviour. The entries are dropped because the store belongs to this hostd; the PANES do
    /// not, and superd hands them back to the next one.
    func relinquishAll(completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let entries = Array(store.values)
        store.removeAll()
        lock.unlock()
        let group = DispatchGroup()
        for entry in entries {
            entry.ttlTask?.cancel()
            group.enter()
            entry.session.relinquishDetached { group.leave() }
        }
        if let completion { group.notify(queue: .global(qos: .utility), execute: completion) }
    }

    // MARK: Test seams

    /// Returns the session IDs currently in the store (testing only).
    var storedIDsForTesting: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(store.keys)
    }

    /// Returns the entry count (testing only).
    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.count
    }
}
