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
            entries[key]?.pendingAcquires -= 1
            // openChannel only throws when the shared link is already dead (the send failed) — so the
            // whole connection is unusable. If no OTHER channel is live AND no other acquire is in
            // flight on this endpoint, drop the dead connection + entry so the next acquire builds a
            // fresh one instead of reusing a corpse (leak-on-throw). A surviving sibling/pending keeps it.
            if (entries[key]?.channelIDs.isEmpty ?? true) && (entries[key]?.pendingAcquires ?? 0) == 0 {
                entries.removeValue(forKey: key)
                await connection.close()
            }
            throw error
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
                entries.removeValue(forKey: key)
                await existing.connection.close()
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
        guard entries[key] != nil else { return }   // a concurrent release already tore the entry down
        entries[key]?.channelIDs.remove(channelID)
        // Tear down only when the LAST channel is gone AND no acquire is mid-open (pendingAcquires),
        // so an in-flight acquire's channel is never stranded on a just-closed connection.
        if entries[key]?.channelIDs.isEmpty == true && (entries[key]?.pendingAcquires ?? 0) == 0 {
            entries.removeValue(forKey: key)
            await connection.close()
        }
    }
}
