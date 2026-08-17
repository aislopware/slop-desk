// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation.
// Shared by the connection cluster (`ConnectionCluster`, both platforms) and the Peek & Reply header so
// the copy + retry policy can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this adds only the view-layer help text, retry gating, and agent glyph/tint.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskAgentDetect
import SlopDeskClientCore
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
    /// `.working` takes ``thinkingMark``'s ink BY REFERENCE, not by agreement: the compact surfaces
    /// now mount the rail's own spinner for that reading, so a second spelling of the ink here would
    /// be a second chance to disagree about one pane.
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none,
             .idle: Slate.Text.secondary
        case .working: thinkingMark.ink
        case .done: Slate.StatusInk.ok
        case .needsPermission: Slate.StatusInk.warn
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    // MARK: Tab badge

    /// A `needsAttention` state's HUE on the hue budget: amber = act-now (a question waits), red
    /// = broken, green = unread-done. `nil` for every non-attention kind. This ink is worn by the row's
    /// trailing ring mark (``statusDot(working:badge:)``), the collapsed-group roll-up count
    /// (``attentionRollupInk(_:)``) and — for the URGENT pair only — the row's title
    /// (``urgentInk(_:)``), so every surface names one pane's state in the same hue. Everything holds STILL (MERIDIAN's hard-cut ethos: nothing
    /// in the rail animates).
    ///
    /// The hues are ``Slate/StatusInk`` — the INK cut of the vocabulary, not the system `Status` set.
    /// A ring mark 10 pt across is the thinnest thing in the rail that carries state, so it is exactly
    /// where a hue tuned for filled controls failed worst (systemGreen measured 2.05 on this cream). The
    /// tier also matters because this mark is drawn on BOTH grounds: the cream in an ordinary row and
    /// the glass face inside the selected row's compact island, and each side of the pair is solved
    /// against its own.
    ///
    /// ⚠️ The system palette was tried for the MARK COLUMN ALONE on 2026-08-11 (user-directed) and
    /// REVERTED the same day on hardware — see `docs/DECISIONS.md`. The measurement it lost on is the
    /// one written above, and the loudest case was the thinking cell: systemYellow lands at **1.46**
    /// on the cream, quieter than the DISABLED slot beside it. Do not re-propose it without a
    /// different ground under the marks.
    static func attentionInk(_ kind: TabBadgeKind) -> Color? {
        switch kind {
        // Awaiting input — act-now amber; red stays reserved for broken.
        case .awaitingInput: Slate.StatusInk.warn
        // Error — the red every terminal already means by red text.
        case .error: Slate.StatusInk.err
        // The clean finish — fresh flash and settled unread alike hold the green until the pane is
        // visited. The completed/finished split stays semantic (freshness machinery, control-backend
        // badge tokens).
        case .completed,
             .finished: Slate.StatusInk.ok
        // Running and privilege never recolour the title: busy is the trailing ring's job
        // (``statusDot(working:badge:)``), and the privilege markers are slot text (``tabBadge(_:)``).
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: nil
        }
    }

    /// The TITLE's ink for an URGENT row — the subset of ``attentionInk(_:)`` that means *something is
    /// wrong or stopped and it is waiting on you*: a blocked agent (amber) and a failed command (red).
    /// `nil` for every other kind, which keeps the neutral ladder.
    ///
    /// The rail used to hold the title monochrome on principle — hue was the trailing mark's alone, and
    /// the title spent only a weight step. That held while the loudest state was an unread finish;
    /// user-directed 2026-08-10, the two states that STOP work now carry their hue across the whole row,
    /// because a 10 pt ring at the right edge is a poor place to put the news that a run just broke.
    ///
    /// A FINISH is deliberately not here. Green is the "nothing is wrong, come look when you can" end of
    /// the ramp; recolouring the title for it would leave the urgent pair nothing louder to be. It still
    /// takes the weight step (the mail idiom — bold says *changed*), so an unread finish is legible
    /// without spending the hue budget's headroom.
    ///
    /// Derived from ``attentionInk(_:)`` rather than respelling the hues, so the title and the mark on
    /// one row can never disagree about which amber or which red.
    static func urgentInk(_ kind: TabBadgeKind) -> Color? {
        switch kind {
        case .awaitingInput,
             .error: attentionInk(kind)
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .completed,
             .finished,
             .running,
             .sudo: nil
        }
    }

    /// The WEIGHT a row's title reads at — the ATTENTION step. A state that waits on you (a question,
    /// a failure, an unread finish) reads bolder than the ACTIVE row's own `.medium`, so "needs you"
    /// outranks "you are here" on the one scale both spend. Everything else stays regular.
    static let attentionWeight: Font.Weight = .semibold

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
    /// (docs/DECISIONS.md round 23). Exactly ONE reading moves — the thinking agent's — and
    /// everything settled holds still. The HUE names the STATE, the SYMBOL names what happened
    /// (``mark(for:agentFinish:)``).
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

    /// The THINKING agent's mark — the drawn braille cell (``AgentSpinner``), on herdr's spinner.
    ///
    /// **The ink is herdr's own YELLOW** (`StatusInk.warn`), user-directed 2026-08-10 after seeing
    /// both on hardware: `info` blue shipped first, on the argument that the attention ramp (amber
    /// question / green finish / red failure) all means *come here* while a thinking agent means the
    /// opposite — and it simply did not carry across the rail. herdr spends yellow on exactly this
    /// state, so this is now the reference's colour as well as its shape.
    ///
    /// ⚠️ That puts it on the SAME hue as ``StatusInk/warn``'s other job, the waiting question. What
    /// keeps them apart is the silhouette and the motion, not the colour: a question is a still HAND,
    /// a thinking agent is a BLOCK OF DOTS with a hole running round it. If a third yellow reading
    /// ever lands in this column, this is the pair that will collide first.
    ///
    /// ⚠️ Splitting the pair by moving this ONE mark to systemYellow was tried and reverted on
    /// 2026-08-11 (user-directed, same day): it separated the hues and cost the mark most of its
    /// contrast on the cream (1.46, under the disabled slot's own 1.60). The silhouette and the
    /// motion stay the separator.
    ///
    /// The accent was tried and rejected on the same pass (the compact glyph used to wear it): in
    /// this app the accent means SELECTION — the reason ``Slate/StatusInk/info`` exists as a separate
    /// blue at all — so a purple mark on an unselected row reads as a row half-selecting itself.
    @MainActor
    static var thinkingMark: StatusDotStyle {
        StatusDotStyle(ink: Slate.StatusInk.warn, mark: .working)
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
    /// A clean exit takes the primary text ink — ``slotNameInk(isCommand:)``'s answer for a running
    /// command too, and DELIBERATELY the same one (round 25, user-directed): the name of a command
    /// no longer changes as it finishes, so the ink is not the completion signal and cannot be read
    /// as one. Green was tried in the mark and is not worth a colour here; "it worked" is the
    /// expected outcome, and spending a hue on the expected leaves nothing to spend on the exception.
    ///
    /// ⚠️ Round 26 (user-directed) changed WHAT this inks for a clean exit: the succeeded receipt no
    /// longer prints a name, so this is the TICK's ink now — the primary, inherited whole from the
    /// word it replaced. The failed answer is unchanged, because a failure still prints its name.
    static func outcomeInk(_ outcome: CommandOutcome) -> Color {
        switch outcome {
        case .succeeded: Slate.Text.primary
        case .failed: Slate.StatusInk.err
        }
    }

    /// The SYMBOL a command's outcome takes in the trailing slot — a bare `checkmark` for a clean
    /// exit, NOTHING for a failure. Non-`nil` here means the slot prints the GLYPH ALONE; `nil` means
    /// it prints the NAME alone. One rule, two readings, and never both at once.
    ///
    /// ⚠️ Round 25 (user-directed) put a glyph back on a command's exit, sixteen rounds after round
    /// 24 pulled the outcome marks. What makes it a different proposal from the disc round 24 killed:
    /// that one lived in the MARK COLUMN, competing with the agent's own alphabet; this one is in the
    /// SLOT, which is the command's own voice. The mark column stays the agent's —
    /// ``mark(for:agentFinish:)`` is still `nil` for every command tier, and
    /// `testEveryBadgeHasExactlyOneVoice` still holds.
    ///
    /// ⚠️ Round 26 (user-directed) dropped the NAME from the clean exit, so the tick stopped being
    /// punctuation on a printed word and became the whole receipt. A finished pane is the one the
    /// reader is done with, and a slot that keeps naming it spends a 10pt column restating history
    /// the tooltip already holds; "it worked" fits in a glyph, and the row goes quiet the moment the
    /// work is over. The tick takes the register the word left behind — the primary ink
    /// (``outcomeInk(_:)``) at ``StatusDot/receiptCheckSize`` — so the slot does not also get fainter
    /// as it gets shorter.
    ///
    /// A failure still gets no glyph, and still prints its NAME. Red is already the exception's whole
    /// budget, and a cross beside a red word is the same news twice — the very fault that cost the
    /// disc its place. The asymmetry is now the round's point rather than a detail of it: a clean
    /// exit is a fact you only have to acknowledge, a broken one is a fact you have to ACT on, and
    /// the one you have to act on is the one that keeps its name.
    static func outcomeSymbol(_ outcome: CommandOutcome) -> SFSymbol? {
        switch outcome {
        case .succeeded: .checkmark
        case .failed: nil
        }
    }

    /// The WEIGHT the trailing slot sets a COMMAND's name in — bold, running or finished, clean or
    /// broken, for the reason the git line weights its counts: at the 10pt instrument size a regular
    /// weight leaves the brightness step alone carrying the signal, and it isn't enough.
    ///
    /// ⚠️ Round 25 (user-directed) widened this from the receipt to the running label as well, and
    /// that is what forced ``outcomeSymbol(_:)`` into existence: while the weight stepped up only at
    /// the end, WEIGHT WAS the completion signal, and a command that is bold the whole way through
    /// has to be given the news back some other way.
    static let slotNameWeight: Font.Weight = .bold

    /// The INK the trailing slot's resting label reads in, for a real program (`make`, `vim`) versus
    /// a bare login shell (`zsh`).
    ///
    /// A COMMAND takes the primary ink and ``slotNameWeight`` — the same register it will keep once
    /// it exits, so the row does not brighten at the finish line. A bare SHELL stays on the tertiary
    /// metadata grey at the regular weight: it is the answer to "what is this pane running" for a
    /// pane that is running nothing, and bolding every idle `zsh` on the rail would spend the whole
    /// step this round is trying to reserve for work. The split is
    /// ``RailRowsBuilder/slotLabelIsCommand(_:)``'s.
    static func slotNameInk(isCommand: Bool) -> Color {
        isCommand ? Slate.Text.primary : Slate.Text.tertiary
    }

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
