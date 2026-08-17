import CSlopDeskFFI
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
    /// agent-mark (`StatusDotView`) tooltip/accessibility text both read this ONE source so they cannot drift.
    /// `none` → "idle" so a fallback summary is never the literal word "none".
    public var displayLabel: String {
        var out = [UInt8](repeating: 0, count: 32)
        let needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_agent_status_display_label(ffiByte, buffer.baseAddress, buffer.count)
        }
        guard needed > 0, needed <= out.count else { return "idle" }
        return String(bytes: out[0..<needed], encoding: .utf8) ?? "idle"
    }

    /// Rollup priority — STRICTLY increasing urgency. A session's status = the
    /// most-urgent over its panes (Herdr: blocked > working > done > idle > none).
    /// Total order: `none(0) < idle(1) < done(2) < working(3) < needsPermission(4)`.
    public var urgency: Int { Int(slopdesk_agent_status_urgency(ffiByte)) }

    /// The inverse of ``urgency`` — maps the raw wire `state` byte of a
    /// ``SlopDeskProtocol.WireMessage/claudeStatus(state:kind:label:)`` (type 27) back to a
    /// `ClaudeStatus` on the client (docs/42 W11). The wire carries the urgency byte rather than the
    /// enum so `SlopDeskProtocol` need not depend on this module; the client maps it back here.
    ///
    /// **Forward-tolerant (validate-then-repair).** An unknown / future urgency byte the host has not
    /// agreed on degrades to `.none` rather than trapping — a hostile or newer datagram can never crash
    /// the client (CLAUDE.md untrusted-input contract). `0…4` round-trip `urgency` exactly.
    public init(urgency: Int) {
        // Clamped rather than truncated: a negative or oversized Int is exactly the hostile datagram
        // the crate's own `from_urgency` degrades to `.none`, and it must reach it as such.
        let byte = UInt8(exactly: urgency) ?? UInt8.max
        self.init(ffiByte: slopdesk_agent_status_from_urgency(byte))
    }

    /// Most-urgent rollup over a set of per-pane statuses (the sidebar/tab dot).
    /// Empty → `.none`. Commutative; ties impossible (`urgency` is a total order).
    public static func rollup(_ statuses: some Sequence<Self>) -> Self {
        var bytes = statuses.map(\.ffiByte)
        let winner = bytes.withUnsafeMutableBufferPointer { buffer in
            slopdesk_agent_status_rollup(buffer.baseAddress, buffer.count)
        }
        return Self(ffiByte: winner)
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

/// The WIRE shape of one type-27 emission — the three fields the machine resolves, captured so a
/// dedupe anchor compares what actually goes out rather than the richer ``ClaudeStatus``.
///
/// Two panes at the same ``ClaudeStatus`` can still owe different frames (a different label, a
/// different notification kind), and two at different statuses can owe the same one. Only the triple
/// answers "would this frame be a repeat", which is the question every emitter here is asking.
///
/// It lives beside the status rather than inside one emitter because it is the WIRE's shape, not any
/// one emitter's. Two of them anchored on it while it was nested in a third — a foreground-watch
/// reducer that folded its own second `ClaudeStatusMachine` (``rust/slopdesk-agent``'s
/// `machine`) and that nothing in the host had
/// constructed since agent detection was fused into one machine per pane.
public struct ClaudeStatusTriple: Sendable, Equatable {
    /// The status urgency byte.
    public let state: UInt8
    /// The notification kind, or `0` for a transition that carries none.
    public let kind: UInt8
    /// The display label, or empty.
    public let label: String

    public init(state: UInt8, kind: UInt8, label: String) {
        self.state = state
        self.kind = kind
        self.label = label
    }
}
