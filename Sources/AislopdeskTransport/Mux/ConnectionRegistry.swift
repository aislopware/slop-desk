import Foundation

/// Refcounted pool of shared ``MuxNWConnection``s, ONE per `host:port` — the heart of
/// "share one TCP connection per host across many panes" (TCP-mux S1).
///
/// ## The single invariant it enforces
/// All panes targeting the SAME `(host,port)` ride ONE shared ``MuxNWConnection`` (one CONTROL +
/// one DATA socket-pair), each as a distinct logical channel. The pool refcounts channels per
/// endpoint and tears the shared connection down **only when the LAST channel closes** — so a
/// single pane closing or reconnecting never drops the connection the other panes ride (the
/// subtlest required behaviour, spec §4 / §8.3).
///
/// ## `@MainActor` + synchronous query
/// `WorkspaceStore.reconcile()` materializes sessions synchronously and inline, so the pool's
/// endpoint bookkeeping must be queryable without an `await`. The pool is `@MainActor` and its
/// endpoint bookkeeping are plain main-actor reads. Acquiring/releasing a channel IS async (it
/// opens/closes sockets), but that happens later inside `MuxClientTransport.connect/close`, never on
/// `reconcile`'s synchronous path.
///
/// ## Headless-testable
/// The physical ``MuxNWConnection`` is built via an injected `makeConnection` factory, so the
/// pool's refcount/teardown logic is provable with an in-memory connection (no socket, no
/// `HostServer`). Production injects a factory that opens real `NWConnection`-backed links.
@MainActor
public final class ConnectionRegistry {
    /// One shared connection's pool entry: the connection + the set of live channel ids on it.
    private struct Entry {
        let connection: MuxNWConnection
        var channelIDs: Set<UInt32> = []
        /// In-flight `acquire`s that hold this shared connection but have not yet inserted their
        /// channelID (they are suspended in `openChannel`). A `release` that empties `channelIDs`
        /// must NOT tear the connection down while one of these is mid-flight, else the acquiring
        /// pane is stranded with a channel on a closed connection. Reserved BEFORE `openChannel`,
        /// cleared after (success or throw) — the subsequent-acquire analogue of the `building`
        /// coalescer's first-acquire TOCTOU guard.
        var pendingAcquires: Int = 0
    }

    /// Keyed by the canonical `host:port` string. One entry == one shared physical connection.
    private var entries: [String: Entry] = [:]

    /// In-flight first-acquire builds, keyed by endpoint. Coalesces concurrent first acquisitions
    /// for the SAME new endpoint onto ONE `makeConnection` so two panes connecting to a never-seen
    /// host near-simultaneously share one connection instead of orphaning a second (the first-acquire
    /// TOCTOU: `makeConnection` is awaited before the entry is stored, so a naive nil-check races).
    private var building: [String: Task<MuxNWConnection, Error>] = [:]

    /// Endpoints the app-global connection has PINNED (docs/31 connect-gate). The shared connection for
    /// a pinned key stays up even with ZERO channels, so the gate can establish the mux BEFORE any pane
    /// opens a channel and it survives closing the last pane. `pin`/`unpin` toggle membership; the
    /// last-channel teardown guards additionally require the key to be un-pinned. There is exactly one
    /// pinned key at a time in practice (the single app target), but the set generalizes cleanly.
    private var pinnedKeys: Set<String> = []

    /// Builds a fresh shared connection for an endpoint (opens the CONTROL + DATA links + starts
    /// the receive loops). Injected so tests substitute an in-memory connection.
    private let makeConnection: @MainActor (_ host: String, _ port: UInt16) async throws -> MuxNWConnection

    /// - Parameters:
    ///   - makeConnection: factory for a fresh shared connection (production: real NWConnections).
    public init(
        makeConnection: @escaping @MainActor (String, UInt16) async throws -> MuxNWConnection
    ) {
        self.makeConnection = makeConnection
    }

    /// The canonical pool key for an endpoint.
    private static func key(_ host: String, _ port: UInt16) -> String { "\(host):\(port)" }

    /// The number of distinct shared connections currently pooled (one per active host). A test
    /// asserts this is 1 for N same-host panes.
    public var sharedConnectionCount: Int { entries.count }

    /// The number of live channels on the shared connection for `(host,port)`, or 0 if none.
    public func channelCount(host: String, port: UInt16) -> Int {
        entries[Self.key(host, port)]?.channelIDs.count ?? 0
    }

    // MARK: - Acquire / release (driven by MuxClientTransport)

    /// Acquires a channel on the shared connection for `(host,port)`, creating the connection on
    /// the FIRST acquisition for that endpoint and reusing it thereafter (refcount++). Opens one
    /// logical channel and returns its data + control sub-channel pair.
    public func acquire(
        host: String,
        port: UInt16,
        sessionID: UUID,
        lastReceivedSeq: Int64
    ) async throws -> MuxAcquisition {
        let key = Self.key(host, port)
        let connection = try await sharedConnection(host: host, port: port, key: key)
        // Reserve a refcount slot BEFORE the openChannel suspension so a concurrent last-channel
        // `release` cannot tear this connection down while we are mid-open (release checks
        // pendingAcquires). Mirrors the post-await in-place mutation discipline below.
        //
        // Create-or-fetch the entry FIRST (idempotent): a COALESCED first-acquire returns its
        // connection via the `building` task (line ~119) WITHOUT creating the entry — only the build
        // CREATOR stores `entries[key]` (line ~126). Awaiters of one `Task.value` are NOT guaranteed to
        // resume in registration order, so a coalescer can reach this line BEFORE the creator runs that
        // store, leaving `entries[key]` nil. The optional-chained `+= 1` would then SILENTLY NO-OP
        // (under-count), but the matching `-= 1` (success/throw paths below) still runs → pendingAcquires
        // goes NEGATIVE → the last-channel teardown guard `(pendingAcquires ?? 0) == 0` never holds → the
        // shared connection (and both panes' sockets) leak FOREVER. Anchoring the reservation on a
        // guaranteed-present entry closes the race; `Entry(connection:)` reuses the connection
        // `sharedConnection` just returned (the same instance every coalescer shares).
        if entries[key] == nil { entries[key] = Entry(connection: connection) }
        entries[key]?.pendingAcquires += 1
        let pair: (data: MuxSubChannel, control: MuxSubChannel)
        do {
            pair = try await connection.openChannel(
                sessionID: sessionID,
                lastReceivedSeq: lastReceivedSeq,
                channelClass: 0
            )
        } catch {
            // IDENTITY-GATE the cleanup (R8 #1, mirrors `release()` / `sharedConnection`): only touch
            // entries[key] if it is STILL our connection. A dead-eviction can rebuild entries[key] under
            // a DIFFERENT connection while `openChannel` is suspended; our `pendingAcquires` reservation
            // went with the OLD (removed) entry, so decrementing the FRESH one underflows it. If rebuilt
            // under us, just ensure our corpse is closed.
            if entries[key]?.connection === connection {
                entries[key]?.pendingAcquires -= 1
                // openChannel only throws when the shared link is already dead (the send failed) — so the
                // whole connection is unusable. If no OTHER channel is live AND no other acquire is in
                // flight on this endpoint, drop the dead connection + entry so the next acquire builds a
                // fresh one instead of reusing a corpse. A surviving sibling/pending keeps it.
                if (entries[key]?.channelIDs.isEmpty ?? true) && (entries[key]?.pendingAcquires ?? 0) == 0
                    && !pinnedKeys.contains(key) {
                    entries.removeValue(forKey: key)
                    await connection.close()
                }
            } else {
                await connection.close() // our corpse may not have been closed by the rebuild; idempotent
            }
            throw error
        }
        // IDENTITY-GATE the success-path mutations too (R8 #1): if a concurrent dead-eviction rebuilt
        // entries[key] under a different connection while `openChannel` was suspended, `connection` is the
        // OLD corpse — the eviction already `close()`d it (finishing these sub-channels) and discarded our
        // `pendingAcquires` reservation with the old entry. Decrementing/inserting into the FRESH entry
        // would underflow ITS pendingAcquires (→ permanent leak) AND collide our stale channelID with the
        // new connection's first channel. Treat as a failed acquire; the caller (ReconnectManager) rebuilds.
        guard entries[key]?.connection === connection else {
            await connection.close() // idempotent — ensure the corpse is fully torn down
            throw AislopdeskTransportError.notConnected("mux connection evicted during channel open")
        }
        entries[key]?.pendingAcquires -= 1
        entries[key]?.channelIDs.insert(pair.data.channelID)
        return MuxAcquisition(channelID: pair.data.channelID, data: pair.data, control: pair.control)
    }

    /// Returns the shared connection for `key`, building it on the first acquisition and reusing it
    /// thereafter. Concurrent first acquisitions for the same endpoint await ONE shared build task
    /// (the `building` pool) so they never each construct a connection and orphan one.
    private func sharedConnection(host: String, port: UInt16, key: String) async throws -> MuxNWConnection {
        if let existing = entries[key] {
            // Evict a DEAD pooled connection ([5]): a link drop (TCP RST / NetBird flap) leaves the
            // shared `MuxNWConnection` unusable but NOT removed from the pool (a surviving sibling
            // channel kept the entry), so a reconnecting pane would otherwise re-acquire the corpse and
            // its `openChannel` would fail forever. If the pooled connection reports `isDead`, drop the
            // entry + close it and fall through to build a FRESH one. A still-live connection is reused
            // as before (the shared-connection invariant).
            if await existing.connection.isDead {
                // IDENTITY-GATED eviction. `await existing.connection.isDead` is a real cross-actor hop
                // into the `MuxNWConnection` actor; while suspended here, a CONCURRENT acquirer for this
                // same key can run, evict this same corpse, and store a FRESH connection. Removing
                // blindly (the prior code) would then delete that fresh entry → the concurrent
                // acquirer's connection is ORPHANED (leaked — `release` can never find it again) AND
                // both panes' first channels collide on id 1 (each connection's `ChannelTable` allocates
                // 1 first), so a later release tears down the WRONG pane. So only evict if the pool STILL
                // holds this exact corpse; if it was rebuilt under us, reuse the fresh connection.
                if entries[key]?.connection === existing.connection {
                    entries.removeValue(forKey: key)
                    await existing.connection.close()
                    // `close()` ALSO suspends — and during it a concurrent acquirer can have fully
                    // built + stored a fresh connection (and cleared `building[key]`). If we then fell
                    // straight through to build, we'd construct a SECOND fresh connection and ORPHAN
                    // one (made.count == 3, one channel stranded). So re-check the pool here: reuse a
                    // rebuilt entry if present; otherwise fall through to the `building` single-flight
                    // below (which shares a concurrent acquirer's IN-FLIGHT build) or build fresh.
                    if let rebuilt = entries[key]?.connection { return rebuilt }
                } else if let rebuilt = entries[key]?.connection {
                    return rebuilt   // a concurrent acquirer already replaced the corpse with a live one
                }
                // else entries[key] == nil (corpse evicted by a concurrent acquirer, its fresh one not
                // yet stored): fall through to the `building` single-flight below, which returns that
                // concurrent acquirer's in-flight build instead of orphaning a second connection.
            } else {
                return existing.connection
            }
        }
        if let inFlight = building[key] {
            return try await inFlight.value      // a concurrent first-acquire is already building it
        }
        let task = Task { @MainActor in try await self.makeConnection(host, port) }
        building[key] = task
        do {
            let connection = try await task.value
            building.removeValue(forKey: key)
            if entries[key] == nil { entries[key] = Entry(connection: connection) }
            return connection
        } catch {
            building.removeValue(forKey: key)
            throw error
        }
    }

    /// Releases a channel from the shared connection (refcount--). Closes the channel; if it was the
    /// LAST channel on that endpoint, tears the shared connection down and drops the pool entry — so
    /// the connection survives exactly as long as at least one pane rides it.
    public func release(host: String, port: UInt16, channelID: UInt32) async {
        let key = Self.key(host, port)
        // Capture ONLY the connection (a stable reference). Do NOT snapshot the value-type `Entry`:
        // `closeChannel` suspends (a real NWConnection write) and this type is @MainActor (reentrant
        // across the await), so a concurrent release/acquire can mutate `entries[key]` while we are
        // suspended. Writing back a pre-await Entry snapshot would clobber that sibling change (lost
        // update) — leaking the shared connection forever (a sibling release's removal is lost), or
        // tearing down a connection a concurrent acquire just opened a channel on (an unrelated pane
        // disconnects a live one). Mutate the LIVE entry AFTER the await, mirroring `acquire`.
        guard let connection = entries[key]?.connection else { return }
        await connection.closeChannel(channelID)
        // `closeChannel` suspends (a real NWConnection write); while suspended, a concurrent
        // dead-eviction in `sharedConnection` can have evicted this (now-dead) connection and stored a
        // FRESH one under `key`. Our `channelID` belonged to the OLD connection, so we must touch the
        // pool ONLY if it STILL holds that exact connection. A bare `entries[key] != nil` check (the
        // prior guard) WRONGLY passes on a rebuild → we would `remove` the fresh entry and `close` the
        // stale connection, orphaning the freshly-built one and stranding the pane riding it. Identity
        // is the correct guard (mirrors `acquire`/`sharedConnection`).
        guard entries[key]?.connection === connection else { return }
        entries[key]?.channelIDs.remove(channelID)
        // Tear down only when the LAST channel is gone AND no acquire is mid-open (pendingAcquires) AND
        // the endpoint is NOT pinned by the app-global connection — so an in-flight acquire's channel is
        // never stranded on a just-closed connection, and a pinned mux survives closing the last pane.
        if entries[key]?.channelIDs.isEmpty == true && (entries[key]?.pendingAcquires ?? 0) == 0
            && !pinnedKeys.contains(key) {
            entries.removeValue(forKey: key)
            await connection.close()
        }
    }

    // MARK: - App-global pin (the connect-gate's mux lifecycle, docs/31)

    /// Establishes (or reuses) the shared connection for `(host,port)` and PINS it so it stays up with
    /// ZERO channels. The connect-gate calls this so the app is "connected" before any pane opens a
    /// channel and stays connected across closing the last pane. Returns when the mux is established;
    /// throws if it cannot be (host unreachable — `makeConnection`'s connect timeout). A re-`pin` after a
    /// drop rebuilds: `sharedConnection` evicts a dead pooled connection regardless of the pin.
    public func pin(host: String, port: UInt16) async throws {
        let key = Self.key(host, port)
        pinnedKeys.insert(key)   // optimistic — protects the build from a racing last-channel teardown
        let connection: MuxNWConnection
        do {
            connection = try await sharedConnection(host: host, port: port, key: key)
        } catch {
            // Build failed: drop the pin we optimistically set, unless a channel / another acquire still
            // wants this endpoint (then leave the entry's own lifecycle in charge).
            if (entries[key]?.channelIDs.isEmpty ?? true) && (entries[key]?.pendingAcquires ?? 0) == 0 {
                pinnedKeys.remove(key)
            }
            throw error
        }
        // A concurrent `unpin()` during the build await removed our pin (its `entries[key]` was still nil
        // mid-build, so it could not tear the not-yet-built connection down). Tear the just-built,
        // now-unpinned, zero-channel connection down instead of ORPHANING it — symmetric to `acquire()`'s
        // post-`openChannel` identity re-check. The `=== connection` gate avoids clobbering a connection a
        // concurrent dead-eviction rebuilt under this key during the await.
        if !pinnedKeys.contains(key),
           entries[key]?.connection === connection,
           (entries[key]?.channelIDs.isEmpty ?? true),
           (entries[key]?.pendingAcquires ?? 0) == 0 {
            entries.removeValue(forKey: key)
            await connection.close()
        }
    }

    /// Removes the pin for `(host,port)` and tears the shared connection down if no channel rides it.
    /// The app-global connection's `disconnect()` calls this; if panes still hold channels, the shared
    /// connection survives until the last one releases (the normal refcount path).
    public func unpin(host: String, port: UInt16) async {
        let key = Self.key(host, port)
        pinnedKeys.remove(key)
        guard let connection = entries[key]?.connection else { return }
        if entries[key]?.channelIDs.isEmpty == true && (entries[key]?.pendingAcquires ?? 0) == 0 {
            entries.removeValue(forKey: key)
            await connection.close()
        }
    }

    /// Whether the shared connection for `(host,port)` is currently established and alive. Used by
    /// ``AppConnection`` to detect a drop (it polls this while connected) so the connect-gate can
    /// reappear and auto-reconnect. `false` when there is no entry or the connection reports `isDead`.
    public func isConnectionAlive(host: String, port: UInt16) async -> Bool {
        let key = Self.key(host, port)
        guard let connection = entries[key]?.connection else { return false }
        return !(await connection.isDead)
    }
}
