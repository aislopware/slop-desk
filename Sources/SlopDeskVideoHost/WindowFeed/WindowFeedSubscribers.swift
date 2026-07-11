import Foundation
import SlopDeskVideoProtocol

// PURE Phase-2 push-feed state (docs/45 §6): the subscriber table (TTL-reaped, renewal-refreshed)
// and the tick/coalesce/burst policy. No clock (callers pass `now`), no sockets — the "decider
// beside the actor" discipline, headless-tested.

/// Who is subscribed to the window feed: channelID → last renewal stamp. A subscriber lives
/// ``ttl`` past its last `windowFeedSubscribe` (3 missed 2 s renewals); expiry hands the caller the
/// ids to `retire` at the mux. Bounded — a hostile spray of distinct channelIDs is capped, newest
/// refused (fail-quiet, the `UnboundByeRateLimiter` shape).
public struct WindowFeedSubscriberTable: Sendable {
    private var lastRenewal: [UInt32: TimeInterval] = [:]
    public let ttl: TimeInterval
    public let capacity: Int

    public init(ttl: TimeInterval = 6.0, capacity: Int = 32) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { lastRenewal.isEmpty }
    public var count: Int { lastRenewal.count }

    /// Records a renewal. Returns `false` when the table is full of FRESH subscribers and this id is
    /// new (refused — bounded map); an existing id always refreshes.
    @discardableResult
    public mutating func renew(_ channelID: UInt32, now: TimeInterval) -> Bool {
        if lastRenewal[channelID] != nil {
            lastRenewal[channelID] = now
            return true
        }
        if lastRenewal.count >= capacity {
            lastRenewal = lastRenewal.filter { now - $0.value < ttl }
            guard lastRenewal.count < capacity else { return false }
        }
        lastRenewal[channelID] = now
        return true
    }

    /// Drops every subscriber whose renewal is ≥ ttl old and returns their ids (the caller retires
    /// those lanes at the mux).
    public mutating func reapExpired(now: TimeInterval) -> [UInt32] {
        let expired = lastRenewal.filter { now - $0.value >= ttl }.map(\.key)
        for id in expired { lastRenewal[id] = nil }
        return expired.sorted()
    }

    /// The live subscriber ids (push targets).
    public func subscribers(now: TimeInterval) -> [UInt32] {
        lastRenewal.filter { now - $0.value < ttl }.map(\.key).sorted()
    }
}

/// The differ's tick + fold policy (docs/45 §6): 1 Hz idle, 4 Hz for 3 s after a STRUCTURAL change
/// (window add/remove/visibility/size); title-only folds coalesce at ≥ 2 s, focus/order-only at
/// ≥ 1 s — churn never enters burst mode and never floods generations.
public struct WindowFeedPushPolicy: Sendable {
    /// What changed between the cached records and a freshly built set.
    public enum Change: Equatable, Sendable {
        case none
        /// Window set / visibility / size changed — fold NOW + burst.
        case structural
        /// Only titles / focus bits / z-order / display ordinals moved — fold on the coalesce gate.
        case volatileOnly(titleChanged: Bool)
    }

    public static let idleTick: TimeInterval = 1.0
    public static let burstTick: TimeInterval = 0.25
    public static let burstWindow: TimeInterval = 3.0
    public static let titleCoalesce: TimeInterval = 2.0
    public static let focusCoalesce: TimeInterval = 1.0

    private var burstUntil: TimeInterval = -.infinity
    private var lastVolatileFold: TimeInterval = -.infinity

    public init() {}

    /// Classifies the diff. Structural = the id SET, any window's visibility bits
    /// (onScreen/minimized/appHidden), or any window's size changed. Everything else the client
    /// renders volatile (title, focus bits, order, display) is `volatileOnly`.
    public static func classify(old: [HostWindowRecord], new: [HostWindowRecord]) -> Change {
        if old == new { return .none }
        let structuralBits: HostWindowFlags = [.onScreen, .minimized, .appHidden]
        func skeleton(_ records: [HostWindowRecord]) -> [UInt32: [UInt16]] {
            Dictionary(uniqueKeysWithValues: records.map {
                ($0.windowID, [$0.widthPt, $0.heightPt, UInt16($0.flags.rawValue & structuralBits.rawValue)])
            })
        }
        guard skeleton(old) == skeleton(new) else { return .structural }
        let titleChanged = Dictionary(uniqueKeysWithValues: old.map { ($0.windowID, $0.title) })
            != Dictionary(uniqueKeysWithValues: new.map { ($0.windowID, $0.title) })
        return .volatileOnly(titleChanged: titleChanged)
    }

    /// Whether this change may fold into the cache NOW (bumping the generation → a push). A
    /// structural change always folds and opens the burst window; a volatile-only change folds only
    /// once its coalesce gate (2 s titles / 1 s focus-order) has elapsed since the last volatile fold.
    public mutating func shouldFold(_ change: Change, now: TimeInterval) -> Bool {
        switch change {
        case .none:
            return false
        case .structural:
            burstUntil = now + Self.burstWindow
            return true
        case let .volatileOnly(titleChanged):
            let gate = titleChanged ? Self.titleCoalesce : Self.focusCoalesce
            guard now - lastVolatileFold >= gate else { return false }
            lastVolatileFold = now
            return true
        }
    }

    /// The differ's next tick interval — 4 Hz inside the structural burst window, 1 Hz otherwise.
    /// (Push pacing ≥ 250 ms is implied: at most one fold per tick.)
    public func tickInterval(now: TimeInterval) -> TimeInterval {
        now < burstUntil ? Self.burstTick : Self.idleTick
    }
}
