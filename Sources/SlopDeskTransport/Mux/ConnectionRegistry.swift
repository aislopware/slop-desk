import CSlopDeskFFI
import Foundation

/// The per-host shared-connection pool, as a handle on `rust/slopdesk-clientnet`'s.
///
/// `docs/63` stage G.3. What used to be here was 316 lines of `@MainActor` bookkeeping over an
/// entry map: a refcount per endpoint, an eviction path for a connection that died under its
/// holders, a pin that kept one alive with no channel on it, and the `makeConnection` seam a test
/// injected to avoid a socket. Every one of those is `ConnectionRegistry`'s in Rust now, reached
/// through `slopdesk_mux_pool_*`, and this type is the handle plus the endpoint spelling.
///
/// ### There is no `makeConnection` seam any more, and that is the point
/// The old one existed so a suite could pool a fake connection. The Rust pool is tested against real
/// loopback sockets in `rust/slopdesk-clientnet/tests/`, which is a stronger proof and a cheaper one
/// — so the seam has no remaining job, and re-exposing it would mean a second dial path that ships.
/// A test that wants a session with no host injects at `PaneDriving` instead, one module up: that is
/// where the LAST decision this pool serves finally leaves Swift, so a double there cannot
/// re-implement any of it.
///
/// ### It is `Sendable`, not `@MainActor`, and that is what the port bought
/// The Swift pool was `@MainActor` because it WAS the mutable state — an entry map, a refcount and
/// an eviction path that had to be serialised by something, and the main actor was the something its
/// callers already had. None of that is here: the state is Rust's, behind its own `Mutex`, and this
/// object is one immutable pointer. So the annotation would now be a hop that guards nothing while
/// still costing every non-main caller one — and there is one, `SlopDeskClient`'s `makeTransport`,
/// which is a synchronous `@Sendable` closure and cannot hop at all. A pool reachable only from the
/// main actor could not serve it without a second dial path, which is the shape G.3 deleted.
public final class ConnectionRegistry: Sendable {
    /// The Rust pool. `nil` only if it could not be created, which nothing observed has ever done.
    private let box: RustHandle

    /// The raw pointer, spelled once so the rest of the file reads as it did before the box.
    private var pool: OpaquePointer? { box.raw }

    /// Wall-clock ceiling on the whole two-socket establishment, including every address a hostname
    /// resolves to. Matches the client's default `handshakeTimeout` (`SlopDeskClient.connect`).
    ///
    /// The Swift this replaced needed a throwing task group and a careful `cancelAll` to bound an
    /// `NWConnection` that parks in `.waiting` forever, plus a `catch` that remembered both half-open
    /// sockets so a failed DATA leg did not leak the CONTROL one. `connect_timeout` is an argument in
    /// Rust and a half-built pair is closed by dropping it, so the group, the race, the cancellation
    /// and the leak are all gone together.
    public static let connectTimeout: Duration = .seconds(10)

    public init(connectTimeout: Duration = ConnectionRegistry.connectTimeout) {
        box = RustHandle(slopdesk_mux_pool_new(connectTimeout.milliseconds))
    }

    deinit {
        // Closes every pooled connection and JOINS its receive loops, so no Rust thread outlives
        // this object. Safe even if a caller leaked a transport: the pool closes rather than waits.
        slopdesk_mux_pool_free(pool)
    }

    /// How many connections the pool holds, across every endpoint.
    public var sharedConnectionCount: Int { slopdesk_mux_pool_connection_count(pool) }

    /// How many channels ride the connection to `host:port`. Zero if there is none.
    public func channelCount(host: String, port: UInt16) -> Int {
        withHost(host) { bytes, count in
            slopdesk_mux_pool_channel_count(pool, bytes, count, port)
        }
    }

    /// Whether a connection to `host:port` is pooled and alive.
    public func isConnectionAlive(host: String, port: UInt16) -> Bool {
        withHost(host) { bytes, count in
            slopdesk_mux_pool_is_alive(pool, bytes, count, port)
        }
    }

    /// Holds the connection to `host:port` open with no channel on it, dialling if there is none.
    ///
    /// What a client about to re-open a pane wants, and what the pool would otherwise reap the
    /// moment the last channel closed.
    ///
    /// `async` for the reason ``MuxClientTransport``'s open is: this DIALS, and a dial takes up to
    /// the whole ``connectTimeout``. `slopdesk_mux_pool_pin` blocks the thread that calls it, and its
    /// caller is `AppConnection.connect()` on the main actor — so running it inline would freeze the
    /// UI for ten seconds against a host that is merely down. The hop is what keeps the door
    /// synchronous in Rust, where a blocking dial is the simple correct thing, without that
    /// simplicity landing on the main thread.
    ///
    /// - Throws: ``SlopDeskTransportError/notConnected(_:)`` if the dial failed.
    public func pin(host: String, port: UInt16) async throws {
        let pinned = await offCallerThread { [self] in
            withHost(host) { bytes, count in slopdesk_mux_pool_pin(pool, bytes, count, port) }
        }
        guard pinned else {
            throw SlopDeskTransportError.notConnected("mux: could not reach \(host):\(port)")
        }
    }

    /// Releases a pin, reaping the connection if nothing else holds it.
    ///
    /// `async` for a weaker version of ``pin(host:port:)``'s reason: releasing the LAST hold closes
    /// the connection and joins its receive loops, which is bounded by a socket close rather than by
    /// a dial, but is still not work to do on the main thread.
    public func unpin(host: String, port: UInt16) async {
        await offCallerThread { [self] in
            withHost(host) { bytes, count in slopdesk_mux_pool_unpin(pool, bytes, count, port) }
        }
    }

    /// The raw pool pointer, for ``MuxClientTransport`` to open a channel on.
    ///
    /// `internal` on purpose: a caller outside this file has no door that takes it, and the whole
    /// reason the transport reaches for it rather than holding its own is that the pool is what
    /// makes every pane to one host share ONE mux.
    var handle: RustHandle { box }

    /// The same pointer, for the ONE door outside this module that takes a pool:
    /// `slopdesk_pane_driver_new`, held by `SlopDeskClient`'s `LivePaneDriver`.
    ///
    /// Public because the pane driver is a module UP — it holds the session, which holds channels on
    /// this pool — and the alternative was a `makePaneDriver` here, which would put the driver's
    /// config and its three callbacks inside the transport module that knows nothing about them. The
    /// invariant that makes it safe rather than merely convenient is the one this type exists for:
    /// a driver holds a strong reference to the registry it was built from, so the pool cannot be
    /// freed while a channel rides it — and `slopdesk_mux_pool_free` says exactly that.
    public var rawPool: OpaquePointer? { box.raw }

    /// Lends a host string as the `(ptr, len)` UTF-8 pair every pool door takes.
    private func withHost<T>(_ host: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        let utf8 = Array(host.utf8)
        return utf8.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }

    /// Runs one pool door on a background queue and hands the answer back to the caller's context.
    ///
    /// Only the two doors that can BLOCK use it — the three counting doors take the pool's lock and
    /// return, so wrapping them would buy a thread hop and nothing else.
    private func offCallerThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { resumption in
            DispatchQueue.global(qos: .userInitiated).async {
                resumption.resume(returning: body())
            }
        }
    }
}

public extension Duration {
    /// This duration as whole milliseconds, which is the only unit the mux doors take.
    ///
    /// `public` because the pane driver's doors take the same unit for the same reason, and a
    /// second copy of this conversion in `SlopDeskClient` is exactly the drift the one below
    /// describes — one of the two copies would get the sub-second half right and the other would not.
    ///
    /// Reads the SUB-SECOND half too. Spelling it `components.seconds * 1000` — which both call
    /// sites did — silently floors every duration under a second to zero, so a 50 ms bound became
    /// "no time at all" and the test that asked for one got whatever Rust does with a zero deadline
    /// rather than the fast failure it wanted. Negative durations clamp to zero: the doors read the
    /// argument as unsigned, and a deadline in the past is a deadline of none.
    var milliseconds: UInt64 {
        let components = components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let whole = UInt64(components.seconds) * 1000
        let fraction = UInt64(components.attoseconds) / 1_000_000_000_000_000
        return whole + fraction
    }
}
