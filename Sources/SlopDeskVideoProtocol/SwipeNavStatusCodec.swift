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
/// Wire layout (big-endian), 5 bytes:
/// ```
/// off 0: UInt8   type (=3 swipeNavStatus)
/// off 1: UInt8   eligible   (0/1)
/// off 2: UInt8   slowTier   (0/1 — the host's SLOPDESK_SWIPE_NAV_SLOW operating point)
/// off 3: UInt16  fireTravel (points — the host's clamped SLOPDESK_SWIPE_NAV_TRAVEL)
/// ```
public struct SwipeNavStatusMessage: Equatable, Sendable {
    /// Whether a qualifying swipe would currently be translated into ⌘[/⌘] on the host.
    public var eligible: Bool
    /// Whether the host's slow tier is on (mirrors `SLOPDESK_SWIPE_NAV_SLOW`).
    public var slowTier: Bool
    /// The host's lift-fire travel threshold in points (already clamped to [20, 500]).
    public var fireTravel: UInt16

    public init(eligible: Bool, slowTier: Bool, fireTravel: UInt16) {
        self.eligible = eligible
        self.slowTier = slowTier
        self.fireTravel = fireTravel
    }

    /// On-wire message type byte (distinct from ``CursorUpdate`` =1 / ``CursorShapeMessage`` =2).
    public static let messageType: UInt8 = 3
    /// Encoded size in bytes (fixed).
    public static let encodedSize = 5

    /// Encodes the status (fixed 5-byte big-endian message). Native Swift is the single
    /// source of truth; the wire format is pinned by the `swipeNavStatus` golden vector.
    public func encode() -> Data {
        var out = Data(capacity: Self.encodedSize)
        out.append(Self.messageType)
        out.append(eligible ? 1 : 0)
        out.append(slowTier ? 1 : 0)
        out.appendBE(fireTravel)
        return out
    }

    /// Decodes a status message (wire format pinned by the `swipeNavStatus` golden vector).
    /// A short datagram throws `.truncated` and is DROPPED by the caller, never fatal.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        guard type == messageType else {
            throw VideoProtocolError.malformed("not a swipe-nav status (type \(type))")
        }
        let eligible = try reader.readUInt8() != 0
        let slowTier = try reader.readUInt8() != 0
        let fireTravel = try reader.readUInt16()
        return Self(eligible: eligible, slowTier: slowTier, fireTravel: fireTravel)
    }
}
