import CSlopDeskFFI
import Foundation

/// Swipe-nav status push for the cursor side-channel (type=3): whether the HOST's ⌘[/⌘]
/// swipe translation would currently accept a gesture (frontmost app in the allowlist for a
/// display session; the window's own app for a window session), plus the recogniser knobs the
/// client's peel-feedback mirror must match — the client runs its own ``SwipeNavRecognizer``
/// purely for VISUAL feedback (doc 05 §8), and feedback that disagrees with the host's
/// thresholds would promise fires that never come.
///
/// Rides the cursor socket because that is the existing low-rate host→client UI-state
/// channel. Loss tolerance is pure fire-and-forget: the host re-sends on every frontmost-app
/// change AND on a slow heartbeat, so a lost datagram self-heals within seconds; the client
/// defaults to NOT eligible until the first status arrives — an old host simply never shows
/// the overlay, and the affordance can never lie about an app where ⌘[ would EDIT TEXT.
///
/// Wire layout (big-endian), 6 bytes:
/// ```
/// off 0: UInt8   type (=3 swipeNavStatus)
/// off 1: UInt8   eligible   (0/1)
/// off 2: UInt8   slowTier   (0/1 — the host's SLOPDESK_SWIPE_NAV_SLOW operating point)
/// off 3: UInt16  fireTravel (points — the host's clamped SLOPDESK_SWIPE_NAV_TRAVEL)
/// off 5: UInt8   navFlags   (bit0 canGoBack, bit1 canGoForward, bit2 historyKnown)
/// ```
public struct SwipeNavStatusMessage: Equatable, Sendable {
    /// Whether a qualifying swipe would currently be translated into ⌘[/⌘] on the host.
    public var eligible: Bool
    /// Whether the host's slow tier is on (mirrors `SLOPDESK_SWIPE_NAV_SLOW`).
    public var slowTier: Bool
    /// The host's lift-fire travel threshold in points (already clamped to [20, 500]).
    public var fireTravel: UInt16
    /// The target app's ⌘[ would navigate right now (AX read of its Back command/button).
    /// Meaningless unless ``historyKnown``.
    public var canGoBack: Bool
    /// The target app's ⌘] would navigate right now. Meaningless unless ``historyKnown``.
    public var canGoForward: Bool
    /// The host actually READ the history state this push (`HostNavHistory`). False ⇒ the read
    /// failed or is disabled and the client must FAIL OPEN (treat both directions as navigable
    /// — the pre-gate behavior), never dark.
    public var historyKnown: Bool

    public init(
        eligible: Bool, slowTier: Bool, fireTravel: UInt16,
        canGoBack: Bool, canGoForward: Bool, historyKnown: Bool,
    ) {
        self.eligible = eligible
        self.slowTier = slowTier
        self.fireTravel = fireTravel
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.historyKnown = historyKnown
    }

    /// Lifts one flat record back into the message. Every producer of the record is a door in
    /// `slopdesk-ffi` — the decode below and the host's operating-point config — so this is the
    /// one place the six fields are named on this side.
    public init(wire flat: SlopDeskSwipeNavStatus) {
        self.init(
            eligible: flat.eligible, slowTier: flat.slow_tier, fireTravel: flat.fire_travel,
            canGoBack: flat.can_go_back, canGoForward: flat.can_go_forward,
            historyKnown: flat.history_known,
        )
    }

    /// Whether the chip may show for a swipe in `direction`: known-dead history suppresses the
    /// affordance, UNKNOWN fails open. The HOST's fire path deliberately does NOT apply this —
    /// ⌘[/⌘] into an app that cannot navigate is a validated-menu no-op, so a stale-disabled
    /// read can only ever cost feedback, never a navigation (see DECISIONS, history gate).
    public func allowsChip(_ direction: SwipeNavRecognizer.Direction) -> Bool {
        slopdesk_swipe_nav_allows_chip(wire, direction == .back ? 0 : 1)
    }

    /// The same gate, applied to one peel verdict code — the door's, so the client's chip mirror
    /// never spells the two branches a second time. The status stays flat on this side of the
    /// boundary; only the answer crosses back.
    public func peelGated(verdict: UInt32, direction: UInt32) -> UInt32 {
        slopdesk_peel_history_gated(verdict, direction, wire)
    }

    /// On-wire message type byte (distinct from ``CursorUpdate`` =1 / ``CursorShapeMessage`` =2).
    /// Vended by the codec that writes it — the flag bits stay over there with it.
    public static let messageType = UInt8(slopdesk_swipe_nav_constant(0))
    /// Encoded size in bytes (fixed).
    public static let encodedSize = slopdesk_swipe_nav_constant(1)

    /// Encodes the status (fixed six-byte big-endian message). `rust/slopdesk-video`'s `swipe_nav`
    /// lays the bytes down, including which bit means which direction; the wire format is pinned by
    /// the `swipeNavStatus` golden vector.
    public func encode() -> Data {
        var out = Data(count: Self.encodedSize)
        let written = out.withUnsafeMutableBytes { buffer in
            slopdesk_swipe_nav_status_encode(wire, buffer.baseAddress, buffer.count)
        }
        precondition(written == Self.encodedSize, "the swipe-nav codec and its own fixed size disagree")
        return out
    }

    /// Decodes a status message (wire format pinned by the `swipeNavStatus` golden vector).
    /// A short datagram throws `.truncated` and is DROPPED by the caller, never fatal; a datagram
    /// of another type on this socket is `.malformed` rather than silently read as this one.
    public static func decode(_ data: Data) throws -> Self {
        var flat = SlopDeskSwipeNavStatus()
        let verdict = data.withUnsafeBytes { bytes in
            slopdesk_swipe_nav_status_decode(bytes.baseAddress, bytes.count, &flat)
        }
        switch verdict {
        case UInt32(SLOPDESK_METADATA_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_METADATA_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("not a swipe-nav status")
        default: break
        }
        return Self(wire: flat)
    }

    /// The status flattened for the boundary. Six booleans-and-a-number crossing by value: cheaper
    /// to copy than a handle would be to own, and there is no state here to keep.
    private var wire: SlopDeskSwipeNavStatus {
        SlopDeskSwipeNavStatus(
            fire_travel: fireTravel, eligible: eligible, slow_tier: slowTier,
            can_go_back: canGoBack, can_go_forward: canGoForward, history_known: historyKnown,
        )
    }
}
