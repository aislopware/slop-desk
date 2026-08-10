// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation.
// Shared by the connection cluster (`ConnectionCluster`, both platforms) and the Peek & Reply header so
// the copy + retry policy can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this adds only the view-layer help text, retry gating, and agent glyph/tint.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SwiftUI

// `@MainActor` because the colour mappers read the runtime ``Slate/theme`` (D3) — every call site is a
// SwiftUI view body, all MainActor.
@MainActor
enum StatusPresentation {
    // MARK: Connection

    /// The compact pill label (e.g. "connected", "reconnecting 3/20", "failed").
    static func connectionLabel(_ status: ConnectionStatus) -> String {
        ConnectionPresenter.shortLabel(for: status)
    }

    /// Whether a manual Retry affordance applies (only the give-up states).
    static func showsRetry(_ status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The hover/accessibility help: host + the actionable headline.
    static func connectionHelp(host: String, status: ConnectionStatus) -> String {
        "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
    }

    // MARK: Agent (Claude Code)

    /// The ``StatusGlyph`` reading for an agent status. `nil` ⇒ render nothing (no active agent).
    /// The agent surfaces (iOS toolbar glyph, Peek & Reply header) speak the SAME terminal dialect as
    /// the tab badges — a state edge is one character trading for another in the same mono slot.
    static func agentReading(_ status: ClaudeStatus) -> StatusGlyph.Reading? {
        switch status {
        case .none: nil
        case .idle: .resting
        case .working: .working
        case .done: .done
        case .needsPermission: .awaiting
        }
    }

    /// Tint for an agent status — the SAME hue budget the tab rows speak (``attentionInk(_:)``), so
    /// the iOS toolbar glyph / Peek & Reply header can never disagree with the sidebar about one pane:
    /// needs-permission = amber (act-now; red is reserved for broken), done = green (unread finish),
    /// idle/none = muted (the resting state spends no colour).
    ///
    /// `.working` = accent is this surface's OWN choice, and the one place these two vocabularies
    /// diverge on purpose: the rail says working with MOTION (``thinkingMark``, rounds 22–23)
    /// because it has a mark that can move, while a glyph in a toolbar slot has only its character
    /// and its tint.
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none,
             .idle: Slate.Text.secondary
        case .working: Slate.State.accent
        case .done: Slate.Status.ok
        case .needsPermission: Slate.Status.warn
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    // MARK: Tab badge

    /// A `needsAttention` state's HUE on the hue budget: amber = act-now (a question waits), red
    /// = broken, green = unread-done. `nil` for every non-attention kind. The sidebar row's TITLE
    /// never recolours — this ink is worn by the row's trailing ring mark
    /// (``statusDot(working:badge:)``) and the collapsed-group roll-up count
    /// (``attentionRollupInk(_:)``), so every surface names one
    /// pane's state in the same hue. Everything holds STILL (MERIDIAN's hard-cut ethos: nothing
    /// in the rail animates).
    static func attentionInk(_ kind: TabBadgeKind) -> Color? {
        switch kind {
        // Awaiting input — act-now amber; red stays reserved for broken.
        case .awaitingInput: Slate.Status.warn
        // Error — the red every terminal already means by red text.
        case .error: Slate.Status.err
        // The clean finish — fresh flash and settled unread alike hold the green until the pane is
        // visited. The completed/finished split stays semantic (freshness machinery, control-backend
        // badge tokens).
        case .completed,
             .finished: Slate.Status.ok
        // Running and privilege never recolour the title: busy is the trailing ring's job
        // (``statusDot(working:badge:)``), and the privilege markers are slot text (``tabBadge(_:)``).
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: nil
        }
    }

    /// The COLLAPSED group's roll-up ink: the strongest attention ink among the hidden rows' fused
    /// badges, in the resolver's own urgency order — a waiting question outranks an error outranks
    /// an unread finish — so the header count wears exactly the ink the loudest hidden row would.
    /// `nil` when nothing inside waits (the count keeps the muted metadata ink). Folding a group
    /// shut therefore never hides an agent that needs the eye.
    static func attentionRollupInk(_ badges: [TabBadgeKind?]) -> Color? {
        let present = Set(badges.compactMap(\.self))
        for kind in [TabBadgeKind.awaitingInput, .error, .completed, .finished]
            where present.contains(kind)
        {
            return attentionInk(kind)
        }
        return nil
    }

    /// The row's trailing STATUS MARK — one column, one hue budget, and otty's own silhouettes
    /// (docs/DECISIONS.md round 23). Exactly ONE reading moves — the thinking agent's, which is why
    /// it needs no hue at all — and everything settled holds still. The HUE names the STATE, the
    /// SYMBOL names what happened (``mark(for:agentFinish:)``).
    ///
    /// The ladder: a WORKING AGENT SPINS (``thinkingMark`` — keyed on the RAW `.working` status, so
    /// the badge gate can't kill it; the badge-routed `.running` tier reads identically); a RESTING
    /// CODE AGENT rings on the muted secondary ink (present, spending no hue); a waiting question
    /// raises otty's amber HAND; the agent's own FINISH takes the filled check on green.
    ///
    /// ⚠️ A COMMAND's outcome mounts NO mark (round 24) — it speaks in the trailing SLOT, as the
    /// command's own name in the outcome's ink (``commandOutcome(badge:agentFinish:)``). The mark
    /// column is the agent's alone, so a row whose only news is `make` failing falls back here to
    /// whatever the AGENT in that pane is doing (usually nothing).
    ///
    /// A plain RUNNING command still marks NOTHING: the ring is the agent's column, and a muted ring
    /// on every `npm run dev` row spent it on the one thing the row's own running title already says.
    /// Bare shells and privilege-only rows mount nothing either — the resting rail stays bare.
    ///
    /// - Parameter agentIdle: whether a code agent is present in the pane and AT REST
    ///   (`ClaudeStatus.idle`) — the muted ring's ONLY source. The `claude` process holds the
    ///   shell's OSC-133 block open for its whole lifetime, so a resting agent's row arrives here
    ///   as a bare ``TabBadgeKind/commandBusy`` (or no badge at all): without this input it is
    ///   indistinguishable from a plain long-running command.
    /// - Parameter agentFinish: whether a `.completed`/`.finished` badge is the AGENT's turn ending
    ///   rather than a command's clean exit — the two fuse into one ``TabBadgeKind``, so the badge
    ///   alone cannot say which. Resolved by ``RailRowsBuilder/finishIsAgents(badge:status:unseenDone:)``,
    ///   the SAME predicate that gates showing the agent's final line, so the closed ring and that
    ///   line can never disagree about whose finish it is.
    static func statusDot(
        working: Bool, badge: TabBadgeKind?, agentIdle: Bool = false, agentFinish: Bool = false,
    ) -> StatusDotStyle? {
        if working { return thinkingMark }
        // The resting-agent ring — the floor every non-attention branch below falls back to.
        let resting = agentIdle ? StatusDotStyle(ink: Slate.Text.secondary) : nil
        guard let badge else { return resting }
        switch badge {
        // The agent tier arriving through the badge route ("Badge while processing" ON) reads
        // identically to the raw-working route above.
        case .running: return thinkingMark
        case .awaitingInput,
             .completed,
             .error,
             .finished:
            // A command's outcome has no mark of its own — `mark(for:)` returns nil for it and the
            // row falls back to the agent's own reading, so the two voices can never both fire.
            guard let mark = mark(for: badge, agentFinish: agentFinish), let ink = attentionInk(badge)
            else { return resting }
            return StatusDotStyle(ink: ink, mark: mark)
        // A busy shell says nothing of its own (the row's title already names the command) and the
        // privilege modifiers are slot text, not lifecycle — both fall through to whether a code
        // agent is resting in this pane.
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .sudo: return resting
        }
    }

    /// The THINKING agent's mark — otty's spinner, which is otty's own answer for exactly this
    /// state (`TabBadge.running` shows a 14×14 `NSProgressIndicator` at the row's trailing edge).
    ///
    /// It spends NO hue, and that is the point twice over. The rail's hue budget buys attention
    /// states (amber question, green finish, red failure); an agent merely thinking is not a state
    /// that wants the eye, it is one that answers "is this still alive?" when the eye arrives.
    /// Motion answers that in the present tense, which is exactly what no static mark can forge —
    /// so the working row spends movement instead of colour, and the whole colour budget stays with
    /// the rows that actually need you.
    ///
    /// The ink is carried for the value's sake only: the platform indicator paints itself, which is
    /// what makes it the same spinner as every other spinner on the machine.
    @MainActor
    static var thinkingMark: StatusDotStyle {
        StatusDotStyle(ink: Slate.Text.primary, mark: .working)
    }

    /// WHICH mark an attention state draws — the silhouette that names what happened, the hue
    /// having already named the state, or `nil` for a state that has no mark at all:
    ///
    ///  * a finish takes the CHECK when it is the AGENT's turn ending (both the fresh `.completed`
    ///    flash and the settled `.finished` unread — OUR split there is semantic, never visual).
    ///  * a waiting question raises the HAND, otty's own awaiting badge.
    ///  * a COMMAND's outcome — a clean exit, or a failure (`.error` is always a command's: it can
    ///    only come from a non-zero exit or a held-red `OSC 9;4;2`, never from the agent, whose
    ///    status has no error case) — draws NOTHING. It is the trailing slot's line now
    ///    (``commandOutcome(badge:agentFinish:)``), where it can name the command instead of
    ///    miming it.
    ///  * everything else keeps the agent ring: a live session with nothing to report.
    ///
    /// ⚠️ This set is otty's, and adding to it needs the same bar otty's clears: a silhouette may
    /// only say what the hue cannot. An earlier round invented pictograms per state (`?`, `!`, a
    /// hand-drawn hand) and pulled all of them for reading as fussy detail (docs/DECISIONS.md
    /// rounds 19–21) — the fix was the size and the fidelity, not the idea (round 23). Round 24
    /// then took the command tiers OUT of the set: a disc and a triangle were spending the reader's
    /// glyph budget to say what a bold or a red word says better.
    static func mark(for kind: TabBadgeKind, agentFinish: Bool) -> StatusMark? {
        switch kind {
        case .error: nil
        case .completed,
             .finished: agentFinish ? .agentFinish : nil
        case .awaitingInput: .awaiting
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: .agentRing
        }
    }

    // MARK: Command outcome

    typealias CommandOutcome = RailRowsBuilder.CommandOutcome

    /// Whether this badge is a COMMAND's outcome, and which one — the trailing slot's reading.
    ///
    /// A finish badge fuses the agent's turn ending with a plain command's exit, so `agentFinish`
    /// (``RailRowsBuilder/finishIsAgents(badge:status:unseenDone:)``) decides which speaker it is:
    /// the agent's finish is the check in the mark column, a command's is this. `.error` is always a
    /// command's. `nil` for every live / privilege tier — an outcome is a finished fact.
    ///
    /// This and ``mark(for:agentFinish:)`` partition the badge set between the row's two voices: a
    /// badge that resolves to an outcome here mounts no mark, and vice versa. The rule itself lives
    /// with the receipt (``RailRowsBuilder/commandOutcome(badge:agentFinish:)``), so the mark
    /// resolver and the slot's text can never disagree about who is speaking.
    static func commandOutcome(badge: TabBadgeKind?, agentFinish: Bool) -> CommandOutcome? {
        RailRowsBuilder.commandOutcome(badge: badge, agentFinish: agentFinish)
    }

    /// The INK a command's outcome reads in — TWO answers, brightness plus one hue: a fact that needs
    /// you is BRIGHT, and the only colour spent here is the red that means broken. (This is the slot's
    /// OWN register. It was written as the git line's while that line was monochrome; the git readout
    /// went back to a hue per role on `07da1f5d` and this one deliberately did not follow — a command
    /// has two outcomes, not seven states.)
    ///
    /// A clean exit takes the primary text ink — one full step above the tertiary metadata grey the
    /// resting slot rests on, which is the whole signal: this row DID something. Green was tried in
    /// the mark and is not worth a colour here; "it worked" is the expected outcome, and spending a
    /// hue on the expected leaves nothing to spend on the exception.
    static func outcomeInk(_ outcome: CommandOutcome) -> Color {
        switch outcome {
        case .succeeded: Slate.Text.primary
        case .failed: Slate.Status.err
        }
    }

    /// The WEIGHT a command's outcome reads at — bold, both outcomes, for the reason the git line
    /// weights its counts: at the 10pt instrument size a regular weight leaves the brightness step
    /// alone carrying the signal, and it isn't enough.
    static let outcomeWeight: Font.Weight = .bold

    /// The trailing-slot marker for a ``TabBadgeKind`` — ONLY the privilege modifiers, drawn as
    /// otty draws them: a SHIELD for sudo, a CUP for caffeinate, both muted. They used to be the
    /// mono characters `#` and `∞`, which asked the reader to know a legend; a shield and a cup ask
    /// nothing (docs/DECISIONS.md round 23). Every lifecycle state returns `nil`: those live in the
    /// trailing status mark (``statusDot(working:badge:)``), so their rows keep the shell label.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle? {
        switch kind {
        // otty's own: a Material duotone cup, its exact path data (``OttyIcon/coffee``).
        case .caffeinate: TabBadgeStyle(art: .vector(OttyIcon.coffee), tint: Slate.Text.secondary)
        // otty's own: `shield.fill` at the same 11pt Medium it configures every badge symbol with.
        case .sudo: TabBadgeStyle(art: .symbol(.shieldFill), tint: Slate.Text.secondary)
        case .awaitingInput,
             .commandBusy,
             .commandRunning,
             .completed,
             .error,
             .finished,
             .running: nil
        }
    }

    /// The accessibility / tooltip label for a tab badge, so the otherwise icon-only glyph is VoiceOver-
    /// legible and testable. Pure text — mirrors the `progress-state.md` badge vocabulary.
    static func tabBadgeLabel(_ kind: TabBadgeKind) -> String {
        switch kind {
        case .running: "Agent working"
        case .commandRunning: "Loading"
        case .commandBusy: "Running"
        case .completed: "Completed"
        case .finished: "Finished"
        case .error: "Error"
        case .awaitingInput: "Awaiting input"
        case .caffeinate: "Caffeinated"
        case .sudo: "Privileged"
        }
    }
}

/// The trailing-slot marker for one tab badge (see ``StatusPresentation/tabBadge(_:)``) — a small
/// static privilege glyph. A pure value (no view), so the badge map can be unit-tested without
/// rendering.
struct TabBadgeStyle: Equatable {
    /// Where the drawing comes from. Both cases are otty's artwork exactly: a system symbol it asks
    /// for by name, or path data it embeds — never a redraw of either.
    enum Art: Equatable {
        case symbol(SFSymbol)
        case vector(VectorIcon)
    }

    let art: Art
    let tint: Color
}
#endif
