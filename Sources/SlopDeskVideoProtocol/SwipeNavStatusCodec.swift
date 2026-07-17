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

    /// Whether the chip may show for a swipe in `direction`: known-dead history suppresses the
    /// affordance, UNKNOWN fails open. The HOST's fire path deliberately does NOT apply this —
    /// ⌘[/⌘] into an app that cannot navigate is a validated-menu no-op, so a stale-disabled
    /// read can only ever cost feedback, never a navigation (see DECISIONS, history gate).
    public func allowsChip(_ direction: SwipeNavRecognizer.Direction) -> Bool {
        guard historyKnown else { return true }
        return direction == .back ? canGoBack : canGoForward
    }

    /// On-wire message type byte (distinct from ``CursorUpdate`` =1 / ``CursorShapeMessage`` =2).
    public static let messageType: UInt8 = 3
    /// Encoded size in bytes (fixed).
    public static let encodedSize = 6

    private static let canGoBackBit: UInt8 = 1 << 0
    private static let canGoForwardBit: UInt8 = 1 << 1
    private static let historyKnownBit: UInt8 = 1 << 2

    /// Encodes the status (fixed 6-byte big-endian message). Native Swift is the single
    /// source of truth; the wire format is pinned by the `swipeNavStatus` golden vector.
    public func encode() -> Data {
        var out = Data(capacity: Self.encodedSize)
        out.append(Self.messageType)
        out.append(eligible ? 1 : 0)
        out.append(slowTier ? 1 : 0)
        out.appendBE(fireTravel)
        var flags: UInt8 = 0
        if canGoBack { flags |= Self.canGoBackBit }
        if canGoForward { flags |= Self.canGoForwardBit }
        if historyKnown { flags |= Self.historyKnownBit }
        out.append(flags)
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
        let flags = try reader.readUInt8()
        return Self(
            eligible: eligible, slowTier: slowTier, fireTravel: fireTravel,
            canGoBack: flags & canGoBackBit != 0,
            canGoForward: flags & canGoForwardBit != 0,
            historyKnown: flags & historyKnownBit != 0,
        )
    }
}
