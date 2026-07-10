import Foundation

/// TTL-bounded store for detached (client-disconnected) ``MuxChannelSession`` instances.
///
/// When a client disconnects with `SLOPDESK_DETACH_ENABLED` on, the host calls
/// ``insert(_:key:ttl:)`` instead of shutting the shell down. The session lives here until
/// either (a) the client returns and calls ``claim(_:)`` to reattach, (b) the TTL fires and
/// ``evict(_:)`` kills the shell, or (c) ``drainAll()`` is called on `stop()`.
///
/// **Synchronous by design (audit 2026-07-10 race cluster).** This used to be an actor, which
/// forced every transition through an `await` hop. Two of those hops were load-bearing races:
///
/// 1. `detach → Task { await store.insert }` — the fire-and-forget insert could lose to a fast
///    reconnect's lookup, which then missed the store and spawned a SECOND shell under the same
///    sessionID (orphaned live PTY + two writers interleaving one scrollback journal).
/// 2. `lookup` returned the live session WITHOUT removing it — two concurrent reconnects (or a
///    reconnect racing an armed TTL task) could both obtain the same session; the loser's later
///    `channelClose` then killed the winner's live PTY and deleted its disk journal.
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

    init(maxSessions: Int? = nil) {
        self.maxSessions = maxSessions
    }

    // MARK: Insert

    /// Stores `session` under its `sessionID` (the UUID the client sent in the `channelOpen`)
    /// and arms a TTL eviction task. If the store is full the OLDEST entry is evicted first.
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
        lock.lock()
        if let maxSessions, store.count >= maxSessions,
           let oldest = store.values.min(by: { $0.detachedAt < $1.detachedAt })
        {
            overflowVictim = store.removeValue(forKey: oldest.session.sessionID)
        }

        let ttlTask: Task<Void, Never>? = ttl.map { ttl in
            Task { [weak self] in
                do { try await Task.sleep(for: ttl) } catch { return }
                self?.evict(id)
            }
        }

        store[id] = Entry(session: session, key: key, detachedAt: Date(), ttlTask: ttlTask)
        lock.unlock()

        if let overflowVictim {
            overflowVictim.ttlTask?.cancel()
            overflowVictim.session.shutdownDetached()
        }
    }

    // MARK: Claim (exclusive reattach hand-off)

    /// Atomically TAKES the live session for `sessionID` out of the store — removes the entry
    /// AND cancels its TTL task in one critical section — or returns `nil` if not found /
    /// child already exited.
    ///
    /// Exclusivity is the point (audit #0/#4/#12): of two concurrent reconnects presenting the
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
    func claim(_ sessionID: UUID) -> MuxChannelSession? {
        lock.lock()
        guard let entry = store.removeValue(forKey: sessionID) else {
            lock.unlock()
            return nil
        }
        entry.ttlTask?.cancel()
        lock.unlock()

        if entry.session.isChildExited() {
            entry.session.shutdownDetached()
            return nil
        }
        return entry.session
    }

    // MARK: Remove (clean exit while in store)

    /// Removes the entry WITHOUT killing the shell. Called when the shell exits naturally
    /// (its `onExit` callback fires) while the session is detached — the PTY is already dead,
    /// so there's nothing to kill; we just drop the store entry (TTL task cancelled).
    func remove(_ sessionID: UUID) {
        lock.lock()
        let entry = store.removeValue(forKey: sessionID)
        lock.unlock()
        entry?.ttlTask?.cancel()
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
    }

    // MARK: drainAll

    /// Kills every stored session. Called from `HostServer.stop()`.
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
