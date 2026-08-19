// PeekReplyPresentation — what the Peek & Reply card (⌘⌥J) SAYS, for both of the halves that draw it,
// and the agent readout the rest of the app shares with it.
//
// The peek card is the fifth surface off the shared SwiftUI floor (docs/56 stage D): the Mac draws it
// as an `NSPanel` (``SlopDeskMacUI/MacPeekReplyView``), the phone as a paper card inside
// ``OverlayHostView``. Every string a reader of the card actually reads is decided HERE — the
// header's caption, the queue counter, the note that stands in for a missing question — because a
// half that spelled one of them itself would drift the moment the copy changed on the other.
//
// The card's BEHAVIOUR is not here and never was: ``PeekReplyTarget`` picks the pane,
// ``PeekReplyFormatter`` turns what was typed into the bytes the PTY gets, ``PendingToolSummary``
// collapses the pending call, and ``OverlayCoordinator`` owns the target, the advance and the close.
// All four predate this file and all four are already shared.
//
// ## The agent readout
//
// ``AgentReadout`` is the wider half of this file, and it is here rather than in the view layer for
// the reason ``Slate/Native`` exists: an agent's status has to become a GLYPH and an INK, the Mac
// resolves those to an `NSColor` and the phone to a `Color`, and the mapping from status to MEANING
// must be one value with two views rather than two agreements. What each half keeps is the ladder
// lookup — `Slate.agentInk` and `Slate.Native.agentInk`, two spellings of one rung.

import SlopDeskAgentDetect

// MARK: - The agent readout

/// What an agent's status reads AS in the one-character status slot — the alphabet the tab badges,
/// the iOS toolbar glyph and the peek card's header all speak.
///
/// A state edge is one character trading for another in the same mono slot, which is why this is an
/// enum of READINGS rather than of glyphs: `working` is a drawn braille cell on both platforms and
/// the other three are characters, and a caller that switched on a glyph string could not tell them
/// apart.
public enum AgentReading: Equatable, Sendable {
    /// An agent is present in this pane and at rest.
    case resting
    /// Generating right now — the only reading that MOVES.
    case working
    /// Blocked on a person: a question is waiting.
    case awaiting
    /// The turn ended and the finish is unread.
    case done
}

/// The INK an agent's status is named in — a rung of the status vocabulary, not a colour.
///
/// Four cases and three rungs: `thinking` and `awaiting` both land on the warm one, and they are
/// separate cases anyway because what keeps them apart is the SILHOUETTE and the motion rather than
/// the hue (see ``StatusPresentation/thinkingMark``). Fusing them here would quietly make a future
/// re-tune of one re-tune the other.
public enum AgentInk: Equatable, Sendable {
    /// No agent, or one at rest — the state that spends no colour.
    case muted
    /// Generating.
    case thinking
    /// An unread finish.
    case done
    /// A question waiting on a person.
    case awaiting
}

/// An agent status, as the compact surfaces read it: a glyph, an ink and a word.
///
/// Every surface that names ONE PANE's agent state goes through here — the sidebar's rolled-up
/// readout, the iOS toolbar, and both halves of the peek card — so they can never disagree about the
/// pane the user is watching longest.
public enum AgentReadout {
    /// The glyph reading, or `nil` for "draw nothing" (no agent in this pane).
    public static func reading(_ status: ClaudeStatus) -> AgentReading? {
        switch status {
        case .none: nil
        case .idle: .resting
        case .working: .working
        case .done: .done
        case .needsPermission: .awaiting
        }
    }

    /// The ink that names the state: act-now for a waiting question, the unread-finish green for a
    /// turn that ended, and the resting states spend nothing.
    public static func ink(_ status: ClaudeStatus) -> AgentInk {
        switch status {
        case .none,
             .idle: .muted
        case .working: .thinking
        case .done: .done
        case .needsPermission: .awaiting
        }
    }

    /// The short word — the one source is ``ClaudeStatus/displayLabel``.
    public static func label(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    /// The fixed box every reading is centred in.
    ///
    /// The four readings have different advance widths — a `·`, a `?`, a `●` and a drawn braille
    /// cell — so the BOX is what holds the layout still while a pane's state changes under it. Shared
    /// because both halves must pin the same width, or the header beside the glyph would shift by a
    /// point between platforms.
    public static let glyphBox: Double = 16
}

// MARK: - The peek card's measurements

/// The one dimension the peek card's two scrolling blocks share.
public enum PeekReplyMetrics {
    /// The tallest either scrolling block — the expanded pending-tool input, the recent-output tail —
    /// may grow to before it scrolls instead. One number for both, because a card with two scroll
    /// wells of different heights reads as two unrelated panels rather than as one card.
    public static let scrollMaxHeight: Double = 132
}

// MARK: - The card's words

/// Every string the peek card prints that is not the host's own text.
public enum PeekReplyPresentation {
    /// The header's second line: the agent's word, and — only while a live inspector reports one —
    /// the todo it is on.
    ///
    /// The scent goes LAST on purpose. The line truncates at the tail, so a squeeze eats the prose
    /// first, the `i/n` count second, and the status word never.
    public static func caption(status: ClaudeStatus, scent: String?) -> String {
        let label = AgentReadout.label(status)
        guard let scent else { return label }
        return "\(label) · \(scent)"
    }

    /// The trailing caption when there is no queue to count — a card's name, standing where the
    /// counter would.
    public static let title = "Peek & Reply"

    /// The "N of M" triage counter, or `nil` when this is not a queue.
    ///
    /// A pass-through of ``PeekReplyTarget/queuePosition(status:panes:excluding:)``'s answer into the
    /// one place the two halves both read it from — the counter REPLACES the static caption on the
    /// queue edge, a hard cut, never both at once.
    public static func counter(_ position: (position: Int, total: Int)?) -> String? {
        guard let position else { return nil }
        return "\(position.position) of \(position.total)"
    }

    /// The question block's text, and whether it is the card's own note rather than the agent's.
    ///
    /// A pane with no reported question still gets a card — the status said it was blocked — so the
    /// block prints a note in the supporting ink instead of going blank, and the caller reads
    /// `isPlaceholder` to know which ink that is.
    public static func question(_ question: String?) -> (text: String, isPlaceholder: Bool) {
        guard let question else { return ("The agent is waiting for your input.", true) }
        return (question, false)
    }

    /// The zero-state card's line, for the near-impossible race where the host clears the last
    /// status while the card is up.
    public static let allCaughtUp = "Nothing needs your reply."
}
