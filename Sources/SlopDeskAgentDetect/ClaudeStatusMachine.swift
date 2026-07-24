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
/// `mutating func reduce(_:at:)` returns the new `ClaudeStatus`. Idempotent on duplicate
/// signals; out-of-order / unknown signals never trap (validate-then-drop).
public struct ClaudeStatusMachine: Sendable, Equatable {
    /// Seconds a `.done` status lingers before decaying to `.idle` (docs/41 §4.3 done→idle).
    public let doneToIdleTimeout: TimeInterval

    /// Current rolled-up status.
    public private(set) var status: ClaudeStatus

    /// A short human label (≤ `maxLabel` chars) — last assistant message / permission prompt
    /// text — for the pane chrome chip. `nil` when there is nothing to show.
    public private(set) var label: String?

    /// Absolute time the status entered `.done` (the done→idle decay anchor). `nil` otherwise.
    private var doneSince: TimeInterval?

    /// Where the current `.needsPermission` block came from (`.none` when not blocked). A
    /// conservative manifest `.working`/`.idle` verdict may clear a MANIFEST-sourced block but
    /// stays SUPPRESSED under an authoritative HOOK block — distinguishing the source fixes the
    /// stuck-blocked bug where `applyManifest(.needsPermission)` set the same flag that gated the
    /// manifest branches, so a manifest-set block could never be cleared by a later manifest
    /// verdict (review #5). Set on `enterBlocked`; cleared on any authoritative working/idle/
    /// done/terminal transition (`enter`/`terminate`).
    private var blockSource: BlockSource

    /// The provenance of an active `.needsPermission` block — what gates whether a conservative
    /// manifest verdict is allowed to clear it (review #5).
    private enum BlockSource: Equatable {
        /// Not blocked.
        case none
        /// An authoritative HOOK Notification(permission|waiting) — a manifest verdict must NOT clear it.
        case hook
        /// The no-hooks manifest fallback's strongest cue (a known approval UI) — a later manifest
        /// `.working`/`.idle` MAY clear it (the manifest is the only authority in play).
        case manifest
    }

    /// Cap for `label` — keeps the chip bounded regardless of a hostile/huge hook body.
    public static let maxLabel = 120

    public init(doneToIdleTimeout: TimeInterval = 8) {
        // Ordered max guards a negative / NaN injected timeout (validate-then-clamp; ordered
        // min/max per the repo's NaN-faithful convention, never a bare `<` ternary).
        self.doneToIdleTimeout = Double.maximum(0, doneToIdleTimeout)
        status = .none
        label = nil
        doneSince = nil
        blockSource = .none
    }

    /// Fold one signal at absolute time `now`, returning the new status.
    @discardableResult
    public mutating func reduce(_ signal: ClaudeSignal, at now: TimeInterval) -> ClaudeStatus {
        switch signal {
        case let .processPresent(present):
            if present {
                liftPresenceFloor()
            } else {
                terminate()
            }

        case let .hook(event):
            apply(event, at: now)

        case let .manifestVerdict(verdict):
            applyManifest(verdict, at: now)

        case let .oscTitle(title):
            applyTitle(title)

        case .tick:
            break // pure time advance; decay handled below

        case .userInput:
            // A keystroke into a blocked pane = the modal is being HANDLED. Demote to idle: an
            // answered dialog re-promotes via its own PreToolUse a beat later, and an Esc-cancel
            // (which fires NO Stop hook) leaves idle as the truth. Every other status is
            // untouched — a keystroke never conjures presence, never demotes a live turn, and
            // never cuts the done decay.
            if status == .needsPermission { enter(.idle, label: nil) }
        }

        decayIfDue(now: now)
        return status
    }

    // MARK: - Hook events (authoritative)

    private mutating func apply(_ event: ClaudeHookEvent, at now: TimeInterval) {
        switch event {
        case .sessionStart:
            // Session opened → present & at rest. Clears any stale block/label.
            enter(.idle, label: nil)

        case .userPromptSubmit:
            enter(.working, label: nil)

        case .preToolUse:
            // A tool starting resolves a just-answered permission prompt → working. The raw
            // tool name is not useful chip text (the meaningful label is the Stop message), so
            // working transitions CLEAR the label.
            enter(.working, label: nil)

        case .postToolUse:
            // A tool result is mid-turn → keep working (don't fall back to idle/done here).
            enter(.working, label: nil)

        case let .notification(kind, label):
            switch kind {
            case .permission,
                 .waitingForInput:
                // An authoritative HOOK block — a conservative manifest verdict must NOT clear it.
                enterBlocked(label: label, source: .hook)
            case .other:
                // Informational (auth_success / elicitation_complete) — no status change,
                // but it does corroborate presence (lift the floor off `.none`).
                liftPresenceFloor()
            }

        case let .stop(_, label):
            enter(.done, label: label, at: now)

        case .subagentStop:
            // A subagent stopping does not change the parent pane's coarse status.
            break

        case .sessionEnd:
            terminate()
        }
    }

    // MARK: - OSC title (Claude Code's own busy/rest telltale)

    /// Claude Code writes its state into the terminal title: a Braille-spinner glyph prefix while
    /// a turn runs, a `✳ ` prefix at rest. That is the agent's own emission (not a heuristic
    /// screen scrape), so it corroborates liveness where hooks have gaps — conservatively:
    /// - the SPINNER promotes to `.working` only while claude is already detected (a title never
    ///   conjures presence) and never clears an authoritative HOOK block;
    /// - the REST prefix demotes ONLY a live `.working` → `.idle` (the missed-Stop stuck shimmer);
    ///   `.done` keeps its decay window and a block keeps waiting;
    /// - any other claude-naming title stays the presence floor it always was.
    private mutating func applyTitle(_ title: String) {
        if Self.titleShowsSpinner(title) {
            if status != .none, blockSource != .hook { enter(.working, label: nil) }
            return
        }
        if Self.titleShowsRest(title) {
            if status == .working { enter(.idle, label: nil) }
            return
        }
        if Self.titleNamesClaude(title) { liftPresenceFloor() }
    }

    /// True when the title carries Claude Code's WORKING telltale — a leading Braille-pattern
    /// spinner glyph (U+2800–U+28FF).
    static func titleShowsSpinner(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
    }

    /// True when the title carries Claude Code's AT-REST telltale — the leading `✳` (U+2733).
    static func titleShowsRest(_ title: String) -> Bool {
        title.unicodeScalars.first?.value == 0x2733
    }

    // MARK: - Manifest verdict (conservative fallback)

    private mutating func applyManifest(_ verdict: ClaudeStatus, at now: TimeInterval) {
        switch verdict {
        case .none:
            // Unsure → never downgrade; presence is the floor.
            break
        case .needsPermission:
            // Only the manifest's strongest, conservative signal (a known approval UI). Tagged as a
            // MANIFEST block (NOT hook) so a later manifest verdict can clear it (review #5: the old
            // shared `hookBlocked` flag made a manifest-set block permanent).
            enterBlocked(label: label, source: .manifest)
        case .working:
            // A coarse "working" guess must NOT clear an authoritative HOOK block, but MAY clear a
            // manifest-sourced one (the manifest is the only authority then).
            if blockSource != .hook { enter(.working, label: nil) }
        case .idle:
            if blockSource != .hook, status == .none { enter(.idle, label: nil) }
        case .done:
            // Anchor the done→idle decay clock exactly like the hook `.stop` path — a
            // manifest-sourced done with a nil anchor would never decay (`decayIfDue` requires
            // `doneSince`), latching the pane `.done` until some other signal overrides it.
            if blockSource != .hook { enter(.done, label: label, at: now) }
        }
    }

    // MARK: - State entry helpers

    /// Presence floor — lift `.none` to `.idle`; never downgrade a richer status.
    private mutating func liftPresenceFloor() {
        if status == .none { enter(.idle, label: nil) }
    }

    private mutating func enterBlocked(label: String?, source: BlockSource) {
        blockSource = source
        doneSince = nil
        status = .needsPermission
        if let label { self.label = Self.clampLabel(label) }
    }

    /// Enter a non-blocked status. `at` non-nil marks the done-decay anchor.
    private mutating func enter(_ next: ClaudeStatus, label newLabel: String?, at now: TimeInterval? = nil) {
        blockSource = .none
        status = next
        label = newLabel.map(Self.clampLabel)
        if next == .done {
            doneSince = now
        } else {
            doneSince = nil
        }
    }

    private mutating func terminate() {
        status = .none
        label = nil
        doneSince = nil
        blockSource = .none
    }

    // MARK: - Time-based decay (injected clock)

    private mutating func decayIfDue(now: TimeInterval) {
        guard status == .done, let since = doneSince else { return }
        // Ordered comparison; decay once the elapsed time reaches the timeout.
        let elapsed = now - since
        if elapsed >= doneToIdleTimeout {
            enter(.idle, label: nil)
        }
    }

    // MARK: - Helpers

    private static func clampLabel(_ s: String) -> String {
        // Bound the chip text; validate-then-clamp on a hostile/huge body. Empty → nil.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= maxLabel { return trimmed }
        return String(trimmed.prefix(maxLabel))
    }

    /// True when an OSC 2 title names Claude (e.g. `Claude: my-project`, `✳ Claude Code`).
    static func titleNamesClaude(_ title: String) -> Bool {
        title.range(of: "claude", options: .caseInsensitive) != nil
    }
}

public extension ClaudeStatusMachine {
    /// Convenience: the label, but `nil` when it is empty (the clamp can yield "").
    var displayLabel: String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }
}
