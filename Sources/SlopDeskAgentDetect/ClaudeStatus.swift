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

extension ClaudeStatus: Comparable {
    /// Ordered by `urgency` so `max(...)` over a pane set IS the rollup.
    public static func < (lhs: ClaudeStatus, rhs: ClaudeStatus) -> Bool {
        lhs.urgency < rhs.urgency
    }
}
