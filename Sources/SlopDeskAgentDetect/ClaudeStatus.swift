import Foundation

/// The per-pane Claude Code status the sidebar + pane chrome consume (docs/41 §4.3,
/// docs/42 W7). A `.terminal` pane running `claude` is auto-detected; this is the
/// rolled-up verdict of the detection signals.
///
/// Glyph mapping (docs/42 W7): `none ⚪ | idle 🟢 | working 🟡 | done 🔵 | needsPermission 🔴`.
/// `needsPermission` is the "blocked" state — Claude is stalled on a human (a permission
/// prompt / approval UI / waiting-for-input). Herdr/Warp call it "blocked"; we name it
/// for the dominant cause and expose `isBlocked` for the rollup vocabulary.
public enum ClaudeStatus: String, Sendable, Equatable, Codable, CaseIterable {
    /// No `claude` here (no foreground process, session ended, or never started). ⚪
    case none
    /// Claude is present and at rest — an empty compose box, awaiting a fresh prompt. 🟢
    case idle
    /// Claude is actively working a turn (a prompt was submitted / a tool is running). 🟡
    case working
    /// Claude finished a turn and is waiting to be seen (decays to `idle`). 🔵
    case done
    /// Claude is BLOCKED on a human: a permission prompt, approval UI, or waiting-for-input. 🔴
    case needsPermission

    /// True when this status demands human attention (the "blocked" bucket).
    public var isBlocked: Bool { self == .needsPermission }

    /// A short human label for the status — the sidebar activity-summary fallback (P3) and the
    /// ``AgentStatusDot`` tooltip/accessibility text both read this ONE source so they cannot drift.
    /// `none` → "idle" so a fallback summary is never the literal word "none".
    public var displayLabel: String {
        switch self {
        case .none: "idle"
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .needsPermission: "needs permission"
        }
    }

    /// Rollup priority — STRICTLY increasing urgency. A session's status = the
    /// most-urgent over its panes (Herdr: blocked > working > done > idle > none).
    /// Total order: `none(0) < idle(1) < done(2) < working(3) < needsPermission(4)`.
    public var urgency: Int {
        switch self {
        case .none: 0
        case .idle: 1
        case .done: 2
        case .working: 3
        case .needsPermission: 4
        }
    }

    /// The inverse of ``urgency`` — maps the raw wire `state` byte of a
    /// ``SlopDeskProtocol.WireMessage/claudeStatus(state:kind:label:)`` (type 27) back to a
    /// `ClaudeStatus` on the client (docs/42 W11). The wire carries the urgency byte rather than the
    /// enum so `SlopDeskProtocol` need not depend on this module; the client maps it back here.
    ///
    /// **Forward-tolerant (validate-then-repair).** An unknown / future urgency byte the host has not
    /// agreed on degrades to `.none` rather than trapping — a hostile or newer datagram can never crash
    /// the client (CLAUDE.md untrusted-input contract). `0…4` round-trip `urgency` exactly.
    public init(urgency: Int) {
        switch urgency {
        case 1: self = .idle
        case 2: self = .done
        case 3: self = .working
        case 4: self = .needsPermission
        default: self = .none // 0 or any unknown/future byte → no status
        }
    }

    /// Most-urgent rollup over a set of per-pane statuses (the sidebar/tab dot).
    /// Empty → `.none`. Commutative; ties impossible (`urgency` is a total order).
    public static func rollup(_ statuses: some Sequence<Self>) -> Self {
        var winner: Self = .none
        for s in statuses where s.urgency > winner.urgency {
            winner = s
        }
        return winner
    }
}

/// The `kind` byte of the wire type-27 `claudeStatus(state:kind:label:)` frame — the QUALIFIER on the
/// status byte. Historically it carried only the last hook `Notification` class, which is meaningful
/// while the pane is blocked and `0` otherwise; `quiet` reuses that spare capacity on a NON-blocked
/// status to say something the `state` byte cannot.
///
/// Lives here (not in `SlopDeskProtocol`) for the same reason ``ClaudeStatus/urgency`` does: the wire
/// module carries raw bytes and does not depend on this one. Both ends map through this enum, and the
/// mapping is FORWARD-TOLERANT — an unknown/future byte degrades to ``none`` rather than trapping
/// (CLAUDE.md untrusted-input contract), which is also what makes ``quiet`` additive: an older client
/// that never heard of `4` reads it as a plain unqualified status and behaves exactly as before.
public enum AgentStatusKind: UInt8, Sendable, Equatable, CaseIterable {
    /// No qualifier (the common case — every status that is not a live block).
    case none = 0
    /// `permission_prompt` — the block is an approval request.
    case permission = 1
    /// The block is a waiting-for-input prompt (including `AskUserQuestion`).
    case waitingForInput = 2
    /// Any other `Notification` class (informational).
    case other = 3
    /// QUIET: this status change is BOOKKEEPING, not news — deliver it to the dots and the chrome,
    /// but raise NO attention (no toast, no banner, no sound, no unread badge).
    ///
    /// The one producer today is the `/compact` boundary. A compaction ends the turn with a `Stop`
    /// hook, which the machine now lands on `.idle` instead of `.done` — but `.working → .idle` is
    /// itself the hook-less COMPLETION edge (`AttentionEdge.isCompletion`, herdr's rule for agents
    /// with no Stop hook at all), so the client would still announce the finish the host just
    /// decided not to announce. This byte is how the host says "I know what this transition looks
    /// like; it is not a finish" (user-reported 2026-08-10).
    case quiet = 4

    /// Maps a raw wire byte, degrading an unknown/future value to ``none``.
    public init(wireByte: UInt8) {
        self = Self(rawValue: wireByte) ?? .none
    }

    /// TRUE when the qualified status change must raise no attention (see ``quiet``).
    public var isQuiet: Bool { self == .quiet }
}

extension ClaudeStatus: Comparable {
    /// Ordered by `urgency` so `max(...)` over a pane set IS the rollup.
    public static func < (lhs: ClaudeStatus, rhs: ClaudeStatus) -> Bool {
        lhs.urgency < rhs.urgency
    }
}
