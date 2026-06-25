import AislopdeskProtocol
import Foundation

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
/// exists. That single-actor atomicity is why no early-reply buffer is needed: a reply requires the
/// request to have been sent first (a host round-trip), which cannot complete before the awaiting
/// façade has registered its continuation.
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

    private let timeout: Duration

    public init(timeout: Duration = MetadataRequestRegistry.defaultTimeout) {
        self.timeout = timeout
    }

    /// Mints the next correlation id. Wraps past 0 on the (4-billion-request) overflow so a real
    /// outstanding request is never assigned id 0.
    public func next() -> UInt32 {
        counter &+= 1
        if counter == 0 { counter = 1 }
        return counter
    }

    /// Awaits the reply for `requestID`: returns `(status, payload)` when ``resolve`` lands, or
    /// `(MetadataStatus.error, empty)` after ``timeout`` — so a dropped reply NEVER hangs the caller.
    public func reply(for requestID: UInt32) async -> (status: UInt8, payload: Data) {
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
        guard let cont = waiters.removeValue(forKey: requestID) else { return }
        cont.resume(returning: (status: status, payload: payload))
    }

    /// Cancels every in-flight request, resolving each as `(error, empty)` — called on disconnect/teardown
    /// so a façade awaiting a reply when the session drops unblocks immediately (never hangs).
    public func cancelAll() {
        let stranded = waiters
        waiters.removeAll()
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
