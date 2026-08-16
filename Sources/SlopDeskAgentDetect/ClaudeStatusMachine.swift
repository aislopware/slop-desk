import CSlopDeskFFI
import Foundation

/// A PURE, deterministic per-pane Claude-status state machine (docs/41 §4.3, docs/42 W7).
///
/// **Clock is injected.** Every `reduce` takes an absolute `now: TimeInterval`; the
/// machine NEVER calls `Date()`/`Date.now` (it imports Foundation only for `TimeInterval`,
/// a plain `Double`). This keeps tests deterministic and honours the repo's no-wall-clock
/// convention. The only time-driven transition is `done → idle` after `doneToIdleTimeout`,
/// fired on a `tick` (or any signal) whose `now` reaches the deadline.
///
/// **Signal precedence (defense-in-depth, docs/41 §4.2).**
/// 1. `processPresent(false)` / `sessionEnd` → `.none` (termination wins, clears all state).
/// 2. Authoritative HOOK events set the status directly (UserPrompt/PreTool → working;
///    Notification(permission|waiting) → needsPermission; Stop → done; SessionStart → idle).
/// 3. `processPresent(true)` / OSC `Claude:` title → presence FLOOR `.idle` (only lifts
///    `.none`; never downgrades a richer hook status). The title's spinner/`✳` PREFIXES
///    (Claude Code's own busy/rest telltale) additionally corroborate working/idle — see
///    `applyTitle` for the conservative rules (never past a hook block, rest only demotes
///    a live working).
/// 4. `manifestVerdict` (the no-hooks fallback) is CONSERVATIVE: a `.none` verdict is
///    ignored; `.working`/`.needsPermission` apply ONLY when an authoritative hook block
///    is not already in effect.
///
/// **Two tiers, and what decides which one is in force (2026-08-11).** Precedence alone says
/// which signal wins a collision; it does not say whether a weak signal should be in the argument
/// at all. Once a pane is HOOK-COVERED — ``hasAuthoritativeFeed``, set by the first parsed hook of a
/// session and dropped only when the session ends — the agent is TELLING us its state on every
/// edge, and the screen engine is a heuristic reading of pixels the agent draws for a human. So
/// the screen stops being a peer:
///
/// - **Tier 1 (authoritative)** — hooks, the ctl `report` verb, presence ABSENCE, and a CANCEL
///   keystroke. These change the status, immediately, always.
/// - **Tier 2 (inferred)** — the screen engine, the OSC title, the presence floor. Under coverage
///   the screen may only CORROBORATE; it cannot move the status.
///
/// …with one escape hatch, because hooks are best-effort (the relay can die, a record can be lost,
/// the host can restart mid-session): the machine's `screen_dissent_since`
/// (`rust/slopdesk-agent/src/machine.rs`) times how long the screen has
/// contradicted the authoritative status WITHOUT INTERRUPTION. Past the window the pane drops
/// coverage and the screen applies. Asymmetric on purpose — ``screenDissentToRaise`` is short
/// (a human waiting on an unannounced dialog is the expensive failure) and
/// ``screenDissentToRelease`` is long (a premature release flaps the mark AND mints a false
/// finished turn, which is the failure that was actually reported). Any hook restores coverage and
/// resets the clock instantly.
///
/// This is where SlopDesk diverges from herdr on purpose: herdr has no hook feed, so its screen
/// engine IS its authority and every heuristic has to be load-bearing. Ours is a backstop.
///
/// **Post-exit lockout.** Precedence alone is not enough for teardown, because the terminating
/// signal ARRIVES EARLY: `sessionEnd` is posted while claude is still the PTY foreground, so for
/// a second or so every rung-3/4 signal still describes a live agent and lifts the floor straight
/// back off `.none`. A `sessionEnd` therefore arms ``postExitFloorLockout``, during which no weak
/// signal may lift `.none`; only an authoritative hook clears it. Presence ABSENCE arms nothing —
/// it is the end already observed, not an announcement of one.
///
/// `reduce(_:at:)` returns the new `ClaudeStatus`. Idempotent on duplicate signals; out-of-order
/// or unknown signals never trap (validate-then-drop).
///
/// **Every rule above is `rust/slopdesk-agent::machine`** (docs/55) — the ledger, the two tiers,
/// the dissent windows and the lockout. This is the handle that owns one machine's state and the
/// marshalling that reaches it, which is why it is a `final class` where it used to be a `struct`:
/// its two owners (``ClaudePaneDetector``, ``ForegroundProcessWatcher``) each hold exactly one and
/// never copy it, so reference semantics cost nothing. Overlapping calls on one handle are
/// aliasing UB rather than a lost update, so an owner that ever shares one must serialise.
public final class ClaudeStatusMachine: @unchecked Sendable {
    /// Seconds a `.done` status lingers before decaying to `.idle`.
    public let doneToIdleTimeout: TimeInterval

    /// How long a hook-sourced block is protected from a screen verdict that would clear it — long
    /// enough for the dialog it announced to have painted.
    static let hookBlockScreenOverrideGrace: TimeInterval = slopdesk_agent_machine_constant(1)

    /// After a `sessionEnd`, no weak signal may lift `.none` for this long. Only a hook clears it.
    public static let postExitFloorLockout: TimeInterval = slopdesk_agent_machine_constant(2)

    /// Unbroken screen dissent needed to RAISE a block past an authoritative feed — short, because a
    /// human waiting on an unannounced dialog is the expensive failure.
    public static let screenDissentToRaise: TimeInterval = slopdesk_agent_machine_constant(3)

    /// Unbroken screen dissent needed to RELEASE one — long, because a premature release flaps the
    /// mark and mints a false finished turn.
    public static let screenDissentToRelease: TimeInterval = slopdesk_agent_machine_constant(4)

    /// The label clamp, in bytes.
    public static let maxLabel = Int(slopdesk_agent_machine_constant(5))

    private let handle: OpaquePointer

    public init(doneToIdleTimeout: TimeInterval = slopdesk_agent_machine_constant(0)) {
        self.doneToIdleTimeout = doneToIdleTimeout
        guard let handle = slopdesk_agent_machine_new(doneToIdleTimeout) else {
            // A machine is a few counters and a small ledger; a null here is the allocator being
            // gone, and a detector with no machine would report `.none` for a live agent forever.
            preconditionFailure("slopdesk_agent_machine_new returned null")
        }
        self.handle = handle
    }

    deinit { slopdesk_agent_machine_free(handle) }

    /// The current rolled-up status.
    public var status: ClaudeStatus {
        ClaudeStatus(ffiByte: slopdesk_agent_machine_status(handle))
    }

    /// The last assistant message, clamped — empty when the machine has none.
    public var label: String? {
        var out = [UInt8](repeating: 0, count: Self.maxLabel + 8)
        let needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_agent_machine_label(handle, buffer.baseAddress, buffer.count)
        }
        // -1 is "there is no label" — distinct from a present-but-empty one, which answers 0.
        guard needed >= 0 else { return nil }
        guard needed <= out.count else { return nil }
        return String(bytes: out[0..<needed], encoding: .utf8)
    }

    /// TRUE when the current status change is bookkeeping rather than news (the `/compact` boundary).
    public var isQuiet: Bool {
        slopdesk_agent_machine_is_quiet(handle)
    }

    /// Whether a hook feed has claimed this pane, making the screen engine corroboration rather than
    /// authority.
    public var hasAuthoritativeFeed: Bool {
        slopdesk_agent_machine_has_authoritative_feed(handle)
    }

    /// How many blocking calls the ledger is still holding.
    public var outstandingBlockCount: Int {
        slopdesk_agent_machine_outstanding_blocks(handle)
    }

    /// The `kind` qualifier byte for the standing block, or 0 when nothing is blocking.
    public var standingBlockKind: UInt8 {
        slopdesk_agent_machine_standing_block_kind(handle)
    }

    /// Folds one signal in and returns the resulting status.
    @discardableResult
    public func reduce(_ signal: ClaudeSignal, at now: TimeInterval) -> ClaudeStatus {
        withAgentSignal(signal) { pointer in
            ClaudeStatus(ffiByte: slopdesk_agent_machine_reduce(handle, pointer, now))
        }
    }

    /// Whether this hook event belongs to THIS pane's agent rather than a nested `claude -p`.
    public func accepts(_ event: ClaudeHookEvent) -> Bool {
        withAgentHookSignal(event) { pointer in
            slopdesk_agent_machine_accepts(handle, pointer)
        }
    }

    /// The leading busy spinner in Claude Code's own OSC title.
    static func titleShowsSpinner(_ title: String) -> Bool {
        agentPredicate(title) { bytes, len in slopdesk_agent_title_shows_spinner(bytes, len) }
    }

    /// The leading `✳` rest telltale in Claude Code's own OSC title.
    static func titleShowsRest(_ title: String) -> Bool {
        agentPredicate(title) { bytes, len in slopdesk_agent_title_shows_rest(bytes, len) }
    }

    /// Whether an OSC title names Claude at all.
    static func titleNamesClaude(_ title: String) -> Bool {
        agentPredicate(title) { bytes, len in slopdesk_agent_title_names_claude(bytes, len) }
    }

    /// Whether a title was written by the agent rather than the shell — the shape that lets the
    /// detector stop trusting a shell-written title once the agent has claimed the slot.
    public static func titleIsAgentWritten(_ title: String) -> Bool {
        agentPredicate(title) { bytes, len in slopdesk_agent_title_is_agent_written(bytes, len) }
    }
}

public extension ClaudeStatusMachine {
    /// Convenience: the label, but `nil` when it is empty (the clamp can yield "").
    var displayLabel: String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }
}
