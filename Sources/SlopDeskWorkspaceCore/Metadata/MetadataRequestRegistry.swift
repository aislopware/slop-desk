import Foundation
import SlopDeskProtocol

/// The client-side pending-request map for the host metadata RPC (E4): it mints the monotonic
/// `requestID` that correlates a ``WireMessage/metadataResponse(requestID:status:payload:)`` back to one
/// of several in-flight ``WireMessage/metadataRequest(requestID:verb:payload:)`` (the Details Panel may
/// fire `processes` + `ports` + `gitStatus` at once), parks a continuation per id, and resolves it when
/// the reply lands.
///
/// **It NEVER hangs.** Every ``reply(for:)`` arms a `timeout` (default 5 s) that resolves the SAME id
/// with `(MetadataStatus.error, empty)` if no reply arrives — the belt-and-braces guard for a dropped
/// type-30 (mirrors ``TerminalBlockModel``'s `blockOutputTimeout`). ``cancelAll()`` resolves every
/// in-flight request as `(error, empty)` on a disconnect/teardown so a façade awaiting a reply when the
/// session drops unblocks immediately instead of waiting out the timeout.
///
/// `@MainActor` (like the rest of the view-model layer): registration inside ``reply(for:)`` runs
/// SYNCHRONOUSLY on the main actor before the first suspension, so ``resolve(requestID:status:payload:)``
/// (the inbound-pump fold) and the timeout — also main-actor — can never interleave BEFORE the waiter
/// exists once ``reply(for:)`` has been entered.
///
/// That atomicity used to be stated as a reason no early-reply buffer was needed, on the grounds that
/// "a reply requires the request to have been sent first (a host round-trip), which cannot complete
/// before the awaiting façade has registered its continuation." **That was false, and it cost a
/// dropped reply per race.** `MetadataClient.request` mints the id, `await send(…)`, and only THEN
/// enters ``reply(for:)`` — and that `await` frees the main actor. A reply arriving during it found
/// no waiter, was dropped by ``resolve``, and the request then waited out its whole timeout to
/// answer `(error, empty)`: the Details Panel spinning for five seconds and then showing nothing,
/// with nothing logged. Rare against a real host, routine against a fast one, and reproducible in
/// the suite, where the transport replies immediately.
///
/// So a reply for an id that WAS minted and is still outstanding is now held in ``landed`` until its
/// waiter arrives. A reply for an id that was never minted is still dropped, not buffered — that is
/// a different case (a stray or late type-30, whose id a future request could reuse) and it keeps
/// its own test.
@preconcurrency
@MainActor
public final class MetadataRequestRegistry {
    /// The default per-request timeout: 5 s → resolve `(error, empty)`. Long enough that a slow host
    /// query (git status on a large repo, a directory listing) is not cut off; short enough that a truly
    /// dropped reply never spins the Details Panel forever.
    public static let defaultTimeout: Duration = .seconds(5)

    /// Monotonic request-id source. Starts at 0; ``next()`` pre-increments so the first id is 1 (a host
    /// that echoes a zeroed/defaulted requestID can't be mistaken for a live request).
    private var counter: UInt32 = 0

    /// In-flight requests keyed by id. A single continuation per id (ids are unique per request, so there
    /// is never a collision); resolving / timing out an id removes it, so a late or duplicate reply for a
    /// already-resolved id is dropped (a continuation is resumed at most once).
    private var waiters: [UInt32: CheckedContinuation<(status: UInt8, payload: Data), Never>] = [:]

    /// Ids ``next()`` has minted whose ``reply(for:)`` has not returned yet.
    ///
    /// This is what tells an EARLY reply (the request is in flight, its waiter has not been parked
    /// yet) apart from a STRAY one (nobody minted this id, so nobody is coming for it). Only the
    /// first is worth holding; buffering the second would let a later request that reused the id
    /// find itself falsely pre-resolved.
    private var outstanding: Set<UInt32> = []

    /// Replies that arrived before their waiter did, keyed by id. Bounded by ``outstanding``, and
    /// each entry is removed by the ``reply(for:)`` that consumes it or by ``cancelAll()``.
    private var landed: [UInt32: (status: UInt8, payload: Data)] = [:]

    private let timeout: Duration

    public init(timeout: Duration = MetadataRequestRegistry.defaultTimeout) {
        self.timeout = timeout
    }

    /// Mints the next correlation id. Wraps past 0 on the (4-billion-request) overflow so a real
    /// outstanding request is never assigned id 0.
    public func next() -> UInt32 {
        counter &+= 1
        if counter == 0 { counter = 1 }
        outstanding.insert(counter)
        return counter
    }

    /// Awaits the reply for `requestID`: returns `(status, payload)` when ``resolve`` lands, or
    /// `(MetadataStatus.error, empty)` after ``timeout`` — so a dropped reply NEVER hangs the caller.
    public func reply(for requestID: UInt32) async -> (status: UInt8, payload: Data) {
        // The reply may already be here. `MetadataClient.request` awaits the SEND between minting the
        // id and arriving here, and that await frees the main actor for the fold that calls
        // `resolve` — so against a fast host the answer lands before the waiter is parked. Reading it
        // out here costs one dictionary probe and closes the window from the other side.
        if let early = landed.removeValue(forKey: requestID) {
            outstanding.remove(requestID)
            return early
        }
        defer {
            outstanding.remove(requestID)
            landed.removeValue(forKey: requestID)
        }
        let timeout = timeout
        let timeoutTask = Task { @MainActor [weak self] in
            // A cancelled sleep throws → return WITHOUT firing (the reply already landed and cancelled us).
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.fireTimeout(requestID)
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<
            (status: UInt8, payload: Data),
            Never,
        >) in
            // Synchronous on the main actor (no await between method entry and here) → atomic vs.
            // resolve()/fireTimeout(): the waiter always exists before either can run.
            waiters[requestID] = cont
        }
        timeoutTask.cancel()
        return result
    }

    /// Resolves a pending request from a `metadataResponse` reply (the inbound-pump fold). A reply for an
    /// unknown / already-resolved id is dropped (a stray or late type-30 must not crash or double-resume).
    public func resolve(requestID: UInt32, status: UInt8, payload: Data) {
        if let cont = waiters.removeValue(forKey: requestID) {
            cont.resume(returning: (status: status, payload: payload))
            return
        }
        // No waiter yet. If the id is one WE minted and still owe an answer for, the request is
        // simply mid-flight — hold the reply for the `reply(for:)` that is on its way. If it is not,
        // this is a stray or already-resolved reply and dropping it is the whole point: a later
        // request that reused the id must not find itself pre-resolved by it.
        guard outstanding.contains(requestID) else { return }
        landed[requestID] = (status: status, payload: payload)
    }

    /// Cancels every in-flight request, resolving each as `(error, empty)` — called on disconnect/teardown
    /// so a façade awaiting a reply when the session drops unblocks immediately (never hangs).
    public func cancelAll() {
        let stranded = waiters
        waiters.removeAll()
        // A held early reply belongs to the session that just died: its `reply(for:)` either never
        // arrives or must answer `(error, empty)` like every other stranded request. Dropping both
        // maps here is also what keeps them bounded across a reconnect.
        landed.removeAll()
        outstanding.removeAll()
        for (_, cont) in stranded {
            cont.resume(returning: (status: MetadataStatus.error.rawValue, payload: Data()))
        }
    }

    /// Whether a request for `requestID` is still parked (diagnostics / tests).
    public func isPending(_ requestID: UInt32) -> Bool { waiters[requestID] != nil }

    /// Fires the timeout for a still-pending request, resolving it as `(error, empty)`. A no-op if the
    /// reply already resolved (the waiter is gone) — so a timer that races a real reply never double-fires.
    private func fireTimeout(_ requestID: UInt32) {
        guard let cont = waiters.removeValue(forKey: requestID) else { return }
        cont.resume(returning: (status: MetadataStatus.error.rawValue, payload: Data()))
    }
}
