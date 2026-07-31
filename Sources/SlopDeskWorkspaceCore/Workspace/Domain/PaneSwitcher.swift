import Foundation
import SlopDeskWorkspaceModel

/// The ⌃⇥ switcher's pure model — a frozen most-recently-used ring plus a provisional highlight.
///
/// The unit is the PANE, not the tab, and the ring spans the whole session rather than the active tab.
/// That is the same unit the sidebar lists and the same unit ⌘1…⌘9 lands on, so "the things I can
/// switch between" is ONE set with one order wherever the user meets it. A ring scoped to the active
/// tab would be a switcher that cannot reach most of the workspace; a ring of tabs would name a
/// container when what the user is going back to is a shell.
///
/// This is deliberately NOT the ⌘]/⌘[ pane cycle. That one walks the active tab's split tree
/// POSITIONALLY, which is the right gesture for "the pane next to this one"; this one walks RECENCY
/// across every tab, so a single ⌃⇥ returns to the pane you were last in however far away it sits.
/// Both ship, the way Ghostty / kitty / WezTerm ship ⌃⇥ alongside their positional chords rather than
/// choosing.
///
/// Two properties earn their keep:
///
/// - **The candidate order is a SNAPSHOT.** Committing a switch pushes the chosen pane to the head of
///   the visit ring, so a live-sorted list would reshuffle under a still-held ⌃ and the next ⇥ tap
///   would land somewhere the user never aimed at. The order is computed once, at open.
/// - **The highlight is LOCAL.** Pane focus is an intent the host owns (`.focusPane`); moving the
///   highlight must not stage one, or every tap while cycling would broadcast a focus change to every
///   other client. Only the commit stages an intent.
public struct PaneSwitcher: Equatable, Sendable {
    /// The frozen ring, most-recently-used first. Index 0 is the pane the gesture started on.
    public let candidates: [PaneID]

    /// Where the provisional highlight sits. Always a valid index into ``candidates``.
    public private(set) var highlightIndex: Int

    /// `true` when a HELD modifier opened this (the ⌃⇥ gesture), so releasing that modifier commits.
    /// `false` when it was opened from the palette / menu with nothing held — there, only Return
    /// commits, because a stray modifier release must not pick a pane the user never aimed at.
    public let armedByModifier: Bool

    /// The pane a commit would focus.
    public var highlighted: PaneID { candidates[highlightIndex] }

    /// Freezes the ring and places the opening highlight. Fails when there is nothing to switch
    /// between (fewer than two candidates) so the caller passes ⌃⇥ through instead of swallowing it
    /// into an overlay that cannot do anything.
    ///
    /// Forward opens at index 1 — the previous pane — because press-and-release with no repeat is the
    /// "flip to the last pane" gesture; opening at 0 would make the common case a no-op.
    public init?(candidates: [PaneID], forward: Bool, armedByModifier: Bool) {
        guard candidates.count > 1 else { return nil }
        self.candidates = candidates
        self.armedByModifier = armedByModifier
        highlightIndex = forward ? 1 : candidates.count - 1
    }

    /// Walks the highlight one step, wrapping at both ends. Holding ⌃ and tapping ⇥ never dead-ends,
    /// and ⇧ reverses direction mid-gesture to correct an overshoot.
    public mutating func step(forward: Bool) {
        let count = candidates.count
        highlightIndex = (highlightIndex + (forward ? 1 : -1) + count) % count
    }

    /// Builds the frozen candidate order: the active pane, then recency, then anything never visited.
    ///
    /// - `active` leads even when it is not the ring's head. The visit ring records where THIS device
    ///   navigated, and a device just moved by another client's focus intent has an active pane its
    ///   own ring never saw — leading with the ring head there would make the first ⌃⇥ jump relative
    ///   to somewhere the user is not.
    /// - `mru` entries absent from `ordered` are dropped: a pane can close under a held ⌃, and
    ///   committing onto a dead one stages a focus intent naming a pane the host no longer has.
    /// - `ordered` (the session's flat pane order) supplies both the fallback for a fresh client whose
    ///   ring is empty and the tail of never-visited panes, so every pane stays reachable.
    public static func candidates(active: PaneID?, mru: [PaneID], ordered: [PaneID]) -> [PaneID] {
        let live = Set(ordered)
        var seen = Set<PaneID>()
        var result: [PaneID] = []
        func append(_ id: PaneID) {
            guard live.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }
        if let active { append(active) }
        for id in mru { append(id) }
        for id in ordered { append(id) }
        return result
    }
}
