import Foundation

/// TTL-bounded store for detached (client-disconnected) ``MuxChannelSession`` instances.
///
/// When a client disconnects with `SLOPDESK_DETACH_ENABLED` on, the host calls
/// ``insert(_:key:ttl:)`` instead of shutting the shell down. The session lives here until
/// either (a) the client returns and calls ``lookup(_:)`` to reattach, (b) the TTL fires and
/// ``evict(_:)`` kills the shell, or (c) ``drainAll()`` is called on `stop()`.
///
/// Actor isolation replaces all NSLock guards — no two methods can interleave, so
/// no separate mutex is needed.
actor DetachedSessionStore {
    struct Entry {
        let session: MuxChannelSession
        let key: MuxSessionKey
        let detachedAt: Date
        var ttlTask: Task<Void, Never>?
    }

    private var store: [UUID: Entry] = [:]

    /// Maximum number of concurrently-detached sessions. The OLDEST by `detachedAt` is evicted
    /// (killed) when a new insert would exceed this. Injected so tests can drive overflow headlessly.
    let maxSessions: Int

    init(maxSessions: Int = 64) {
        self.maxSessions = maxSessions
    }

    // MARK: Insert

    /// Stores `session` under its `sessionID` (the UUID the client sent in the `channelOpen`)
    /// and arms a TTL eviction task. If the store is full the OLDEST entry is evicted first.
    ///
    /// - Parameter ttl: time until the shell is automatically killed, or `nil` to keep the
    ///   detached session ALIVE INDEFINITELY — the tmux/zellij semantics and the default (env
    ///   `SLOPDESK_DETACH_TTL_SECS`, unset/`0` = never; the `maxSessions` cap is the resource
    ///   bound). Pass `.milliseconds(10)` in tests.
    func insert(_ session: MuxChannelSession, key: MuxSessionKey, ttl: Duration?) {
        let id = session.sessionID

        // Cap enforcement: evict the oldest entry when full.
        if store.count >= maxSessions, let oldest = store.values.min(by: { $0.detachedAt < $1.detachedAt }) {
            evict(oldest.session.sessionID)
        }

        let ttlTask: Task<Void, Never>? = ttl.map { ttl in
            Task { [weak self] in
                do { try await Task.sleep(for: ttl) } catch { return }
                await self?.evict(id)
            }
        }

        store[id] = Entry(session: session, key: key, detachedAt: Date(), ttlTask: ttlTask)
    }

    // MARK: Lookup

    /// Returns the live session for `sessionID`, or `nil` if not found / child already exited.
    ///
    /// A child-exited session is AUTO-EVICTED on lookup (the zombie would be reaped by
    /// `removeMuxSession` → `shutdown` when `onExit` fires, but if the client reconnects
    /// first we want it to get a fresh shell, not hang on a dead one). Eviction here
    /// calls `shutdownDetached()` rather than `evict()` (the TTL path already killed the
    /// child; here the child exited naturally so we just clean up the fd).
    func lookup(_ sessionID: UUID) -> MuxChannelSession? {
        guard let entry = store[sessionID] else { return nil }
        // If the child already exited while in the store, auto-evict and return nil so the
        // caller (PATH C) falls through to spawn a fresh shell.
        if entry.session.isChildExited() {
            entry.ttlTask?.cancel()
            store.removeValue(forKey: sessionID)
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
        guard let entry = store.removeValue(forKey: sessionID) else { return }
        entry.ttlTask?.cancel()
    }

    // MARK: Evict (TTL / overflow)

    /// Kills and removes the session. Called by the TTL task or the overflow eviction.
    func evict(_ sessionID: UUID) {
        guard let entry = store.removeValue(forKey: sessionID) else { return }
        entry.ttlTask?.cancel()
        entry.session.shutdownDetached()
    }

    // MARK: drainAll

    /// Kills every stored session. Called from `HostServer.stop()`.
    func drainAll() {
        let entries = Array(store.values)
        store.removeAll()
        for entry in entries {
            entry.ttlTask?.cancel()
            entry.session.shutdownDetached()
        }
    }

    // MARK: Test seams

    /// Returns the session IDs currently in the store (testing only).
    var storedIDsForTesting: Set<UUID> { Set(store.keys) }

    /// Returns the entry count (testing only).
    var countForTesting: Int { store.count }
}
