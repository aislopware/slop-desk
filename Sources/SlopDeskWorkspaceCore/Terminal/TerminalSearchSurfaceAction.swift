import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - The five things a search surface can be asked for

/// The CLOSED vocabulary of libghostty binding actions the two search surfaces drive — the INTENT half.
///
/// It sits here, beside ``TerminalSearchController``, rather than beside either bar, because THREE
/// callers speak it and they are not all in one target: the in-pane ⌘F bar (`TerminalFindBarModel`),
/// cross-tab ⇧⌘F click-to-line (``GlobalSearchController/navigationActions(for:query:caseSensitive:isRegex:lines:columns:)``),
/// and copy-mode vi `n`/`N` (``TerminalViewModel``) when no find bar is wired. Each of those three had
/// built the strings inline, which is three copies of one foreign protocol — the exact shape the
/// one-implementation rule exists to prevent, and the worst kind of it, because a typo produces a
/// control that silently does nothing rather than a build error.
///
/// The SPELLINGS are `slopdesk_workspace::find_bar::Action`'s, pinned letter for letter beside the
/// table. They are libghostty's own grammar, parsed by a vendored embedder this side cannot
/// regenerate from, so they cross whole rather than being assembled here from a prefix.
///
/// The two nav actions are one case with a direction rather than two cases, because every caller that
/// has one has already resolved `forward` — through ``forwardStep(repeatingSameWay:searchBackward:)``
/// for the bar's vi `n`/`N`, or directly for the others. Two cases would just move that `if` outward.
public enum TerminalSearchSurfaceAction: Equatable, Sendable {
    /// Arm libghostty's LITERAL in-surface search with `needle` — it then owns the amber highlight and
    /// the scroll-to-match. Only the modes libghostty can express faithfully send this.
    case search(needle: String)
    /// Step libghostty's own stateful search cursor, which moves the highlight and the viewport.
    case navigate(forward: Bool)
    /// End the in-surface search, dropping every highlight it painted.
    case end
    /// Scroll the viewport to a PHYSICAL grid row — the row-driven modes' whole navigation, since
    /// libghostty cannot match what they matched. The row is
    /// ``ScrollbackWrapMapper/physicalRow(forLogicalLine:in:columns:)``'s, never a logical mirror index.
    case scrollToRow(Int)

    /// The binding-action string libghostty's `performBindingAction` parses, or `nil` for an action the
    /// door does not spell.
    ///
    /// The whole string crosses, needle and all. A door answering `"search:"` for this side to append
    /// to would put one grammar in two languages, which is the drift the crossing exists to close; the
    /// copy is nothing beside the scrollback scan the same keystroke already pays for.
    ///
    /// `nil` cannot arise from a case listed above, and that is the point: it is what a *future* case
    /// added on one side and not the other reads as, so an action with no spelling is not sent rather
    /// than sent blank — `performBindingAction("")` is a binding libghostty parses and REJECTS, which
    /// reads in a log as the surface refusing a real action rather than as this side never having had one.
    public var wire: String? {
        var needle = ""
        var forward = false
        var row = 0
        let kind: UInt32
        switch self {
        case let .search(text):
            kind = UInt32(SLOPDESK_WS_FIND_ACTION_SEARCH)
            needle = text
        case let .navigate(direction):
            kind = UInt32(SLOPDESK_WS_FIND_ACTION_NAVIGATE)
            forward = direction
        case .end:
            kind = UInt32(SLOPDESK_WS_FIND_ACTION_END)
        case let .scrollToRow(target):
            kind = UInt32(SLOPDESK_WS_FIND_ACTION_SCROLL_TO_ROW)
            row = target
        }
        var bytes = Array(needle.utf8)
        return bytes.withUnsafeMutableBufferPointer { text in
            wsAnswer { out, cap in
                Int(slopdesk_ws_find_bar_wire(
                    kind, forward, UInt32(clamping: row),
                    text.baseAddress, text.count,
                    out, cap,
                ))
            }
        }
    }

    // MARK: - The two decisions every caller of this vocabulary shares

    /// Whether a mode CANNOT be expressed faithfully by libghostty's own literal search, so the caller
    /// must drive navigation from its OWN match rows.
    ///
    /// Which flags say that, and why the case-sensitive one is among them, is
    /// `slopdesk_workspace::find_bar::needs_row_driven_nav`. Both search surfaces read it, so the ⌘F bar
    /// and ⇧⌘F click-to-line cannot start disagreeing about which modes libghostty can be trusted with —
    /// they disagreed once, and it took a bug report to notice.
    public static func needsRowDrivenNav(
        isRegex: Bool,
        wholeWord: Bool = false,
        caseSensitive: Bool,
    ) -> Bool {
        slopdesk_ws_find_bar_row_driven(isRegex, wholeWord, caseSensitive)
    }

    /// Which way vi's `n` (`repeatingSameWay: true`) / `N` (`false`) steps, given the direction the search
    /// was OPENED in. vim's rule — `slopdesk_workspace::find_bar::nav_forward`.
    public static func forwardStep(repeatingSameWay: Bool, searchBackward: Bool) -> Bool {
        slopdesk_ws_find_bar_nav_forward(repeatingSameWay, searchBackward)
    }

    /// What arming the search does — one verdict over the query and the three mode flags.
    public enum Arming: Equatable, Sendable {
        /// End the in-surface search and stop: an empty field has nothing to highlight, and a stale
        /// highlight under a cleared query is the bug this arm exists to prevent.
        case end
        /// End it, then scroll to the current match's row — the row-driven modes' whole navigation.
        case endThenScroll
        /// Arm libghostty's literal search with the needle; it owns the highlight and the scroll.
        case search
    }

    /// What a keystroke, a toggle or an open does to the live surface.
    ///
    /// One verdict rather than two questions, because the ORDERING is the rule: an empty field outranks
    /// the mode — nothing to search is nothing to search either way — and asking `needsRowDrivenNav`
    /// first would put that precedence in the caller. `slopdesk_workspace::find_bar::Arming`.
    ///
    /// A code the door does not spell reads as ``Arming/end``, which is the arm that clears rather than
    /// paints: the safe answer for a verdict this side could not resolve.
    public static func arming(
        queryEmpty: Bool,
        isRegex: Bool,
        wholeWord: Bool = false,
        caseSensitive: Bool,
    ) -> Arming {
        switch Int32(slopdesk_ws_find_bar_arming(queryEmpty, isRegex, wholeWord, caseSensitive)) {
        case SLOPDESK_WS_FIND_ARM_SEARCH: .search
        case SLOPDESK_WS_FIND_ARM_END_THEN_SCROLL: .endThenScroll
        default: .end
        }
    }
}
