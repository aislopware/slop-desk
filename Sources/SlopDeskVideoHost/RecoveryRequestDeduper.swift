import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-video`'s `recovery_dedupe`, reached through the door of the
/// same name.
///
/// Host-side dedup window for recovery-request datagrams. The client sends each logical
/// `requestLTRRefresh` / `requestIDR` as N byte-identical copies spaced ~3 ms apart
/// (``SlopDeskVideoProtocol/RecoveryRequestRedundancy``); this collapses those copies back to ONE
/// host action.
///
/// WHY the host needs it (and the capturer latch alone is not enough): same-frame duplicates
/// dedup via the capturer's Bool latch, but copies STRADDLING a capture-frame boundary re-latch
/// AFTER the drain — on the LTR path (no cooldown exists there) that encodes a SECOND
/// `ForceLTRRefresh` P-frame and resets `framesSinceAnchor`. Even a 6 ms copy spread straddles the
/// 16.7 ms @60fps boundary often, so dedup here is REQUIRED for the LTR path and
/// belt-and-braces for the IDR path (whose `RecoveryIDRPolicy` admission absorbs duplicates too).
///
/// KEY = the FULL raw datagram bytes (type byte + entire body, including the component-2
/// `lastDecodedFrameID` context). Byte-equality means zero coupling to the wire layout: the
/// client encodes ONCE per logical request and re-sends the identical `Data`, so any future body
/// change is covered automatically. A ring (not a single slot) so interleaved bursts (copies for
/// lost frame N interleaving with copies for frame N+1 — different bytes) both dedup correctly.
/// A duplicate does NOT refresh the original's timestamp: a legitimately identical re-request
/// ages back to admissible one window after the FIRST sighting, never starved by its own copies.
///
/// A HANDLE, and it was already a class: the ring holds WHOLE datagrams across calls and the near
/// side reads exactly one bool back, which is §4b's test answered as plainly as it gets. The
/// degenerate-clock readings — a NaN window admits everything, a NaN `now` keeps every entry — are
/// the crate's, written there as the complements of the obvious comparisons so a broken clock fails
/// toward doing MORE work rather than none.
///
/// No wall clock — the caller injects `now` in seconds.
///
/// `@unchecked Sendable`: the handle is not thread-safe, but every use is single-owner — the
/// host session holds it as an actor-isolated property and the loopback validator / tests drive it
/// from a single thread, so no two threads ever touch it concurrently.
public final class RecoveryRequestDeduper: @unchecked Sendable {
    /// The window and the ring size, from the door, so neither language writes them down twice.
    private static let defaults = slopdesk_recovery_dedupe_defaults()
    public static var defaultWindowSeconds: TimeInterval { defaults.window_seconds }
    public static var defaultCapacity: Int { defaults.capacity }

    /// The admitted payloads still inside the window.
    private let handle: OpaquePointer?

    /// - Parameters:
    ///   - windowSeconds: duplicates of an admitted payload are dropped for this long after its
    ///     FIRST sighting. Sized ≥ 2× the max client copy spread + reorder skew and < every
    ///     legitimate re-request spacing. `0` ⇒ always admit (kill switch).
    ///   - capacity: max remembered payloads (floored to 1).
    public init(
        windowSeconds: TimeInterval = RecoveryRequestDeduper.defaultWindowSeconds,
        capacity: Int = RecoveryRequestDeduper.defaultCapacity,
    ) {
        handle = slopdesk_recovery_dedupe_new(windowSeconds, capacity)
    }

    deinit {
        slopdesk_recovery_dedupe_free(handle)
    }

    /// `true` = first sighting within the window (caller should process); `false` = duplicate
    /// (caller should drop).
    public func admit(_ datagram: Data, now: TimeInterval) -> Bool {
        datagram.withUnsafeBytes { bytes in
            slopdesk_recovery_dedupe_admit(handle, bytes.baseAddress, bytes.count, now)
        }
    }
}
