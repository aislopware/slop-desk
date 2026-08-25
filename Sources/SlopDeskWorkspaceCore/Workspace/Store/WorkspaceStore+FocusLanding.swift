import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × where the focus lands

/// The two questions a shell has to answer about a focus change that the LANDING alone cannot:
/// what asked for it (``WorkspaceStore/FocusIntent``), and — when a pane closes — where the keyboard
/// should go (``WorkspaceStore/paneCloseLanding(closing:)``).
///
/// Lives beside the store rather than in it for the same reason the block ops and the completion
/// badges do: the class body has a length ceiling, and only the stored halves need to be inside it.
public extension WorkspaceStore {
    /// WHAT THE LAST LOCAL NAVIGATION NAMED — a tab, or a pane.
    ///
    /// The landing alone cannot say it. Switching tabs moves the focused pane too (each tab keeps its
    /// own), so a shell watching `(activeTab, activePane)` sees the same shape for "switch to tab B"
    /// and "jump to that pane, which happens to live in tab B" — and those want opposite things from
    /// the keyboard: the first hands the arriving tab whichever surface it was last read in, the
    /// second was aimed at a pane and must land there. Only the two `stageFocus` choke points know
    /// which was asked for, so they say so here.
    ///
    /// The `seq` is what makes a repeat legible: two consecutive pane jumps carry the same `kind`,
    /// and a reader comparing values alone would call the second one stale. It also marks the focus
    /// moves that pass through NEITHER choke point — a split's new leaf, a close's landing, another
    /// client's focus arriving in the document — as exactly that: the sequence stands still while the
    /// landing moves.
    ///
    /// Recorded only when the navigation actually STAGED. A refused focus (a pane that has since
    /// closed, an unfollowing device with no tab for it) moved nothing, and a reader must not be told
    /// otherwise.
    struct FocusIntent: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// `stageFocus(tab:)` — a tab bar click, ⌘-digit, ⌃⇥ commit, session switch.
            case tab
            /// `stageFocus(pane:)` — a leaf click, ⌘-arrow, rail row, palette / search landing.
            case pane
        }

        public var kind: Kind
        /// Monotonic per store, bumped on every recorded intent.
        public var seq: UInt64

        public init(kind: Kind, seq: UInt64) {
            self.kind = kind
            self.seq = seq
        }
    }
}

extension WorkspaceStore {
    /// Records a STAGED navigation's kind (see ``FocusIntent``). Called by the two `stageFocus`
    /// overloads and by nothing else — a third caller would be a claim that some other path is a
    /// deliberate navigation, which is exactly the distinction this value exists to keep.
    func noteFocusIntent(_ kind: FocusIntent.Kind) {
        focusIntentSeq &+= 1
        lastFocusIntent = FocusIntent(kind: kind, seq: focusIntentSeq)
    }

    /// The pane the keyboard should land on when `target` closes: the most recently visited pane that
    /// SURVIVES the close, inside the closing pane's own tab.
    ///
    /// `nil` when the question does not arise — a background pane closing (focus does not move at
    /// all), a pane whose tab goes with it (the tab cascade picks a tab, not a pane), the last two
    /// panes (one survivor, and the geometric rule already agrees), or a ring with nothing live left
    /// in it (the tree op's neighbour rule stands rather than being overridden with a guess).
    ///
    /// The ring's front is the pane being closed, so "most recent survivor" is simply the first entry
    /// that is still there — ``RecentsRing/mostRecentSurvivor(mru:survivors:)``, which is handed one
    /// flag per ring entry and answers a POSITION, so no pane id crosses.
    func paneCloseLanding(closing target: PaneID) -> PaneID? {
        guard let (sessionID, tabID) = tree.tab(containing: target),
              let tab = tree.sessions.first(where: { $0.id == sessionID })?
              .tabs.first(where: { $0.id == tabID }),
              tab.activePane == target
        else { return nil }
        let survivors = Set(tab.allPaneIDs()).subtracting([target])
        guard survivors.count > 1 else { return nil }
        return RecentsRing.mostRecentSurvivor(mru: paneVisitMRU, survivors: survivors)
    }
}
