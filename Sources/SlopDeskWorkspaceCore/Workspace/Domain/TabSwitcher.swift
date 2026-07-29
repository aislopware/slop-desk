import Foundation
import SlopDeskWorkspaceModel

/// The ⌃⇥ tab switcher's pure model — a frozen most-recently-used ring plus a provisional highlight.
///
/// This is deliberately NOT the ⌘⇧]/⌘⇧[ cycle. That one walks the tab bar POSITIONALLY, which is the
/// right gesture for "show me the next tab along"; this one walks RECENCY, so a single ⌃⇥ returns to
/// the tab you were last in however far away it sits. Both ship, the way Ghostty / kitty / WezTerm ship
/// ⌃⇥ alongside ⌘⇧-brackets rather than choosing.
///
/// Two properties earn their keep:
///
/// - **The candidate order is a SNAPSHOT.** Committing a switch pushes the chosen tab to the head of
///   the host's `focusMRU` ring, so a live-sorted list would reshuffle under a still-held ⌃ and the
///   next ⇥ tap would land somewhere the user never aimed at. The order is computed once, at open.
/// - **The highlight is LOCAL.** Tab focus is an intent the host owns (`.focusTab`); moving the
///   highlight must not stage one, or every tap while cycling would broadcast a focus change to every
///   other client. Only the commit stages an intent.
public struct TabSwitcher: Equatable, Sendable {
    /// The frozen ring, most-recently-used first. Index 0 is the tab the gesture started on.
    public let candidates: [TabID]

    /// Where the provisional highlight sits. Always a valid index into ``candidates``.
    public private(set) var highlightIndex: Int

    /// `true` when a HELD modifier opened this (the ⌃⇥ gesture), so releasing that modifier commits.
    /// `false` when it was opened from the palette / menu with nothing held — there, only Return
    /// commits, because a stray modifier release must not pick a tab the user never aimed at.
    public let armedByModifier: Bool

    /// The tab a commit would select.
    public var highlighted: TabID { candidates[highlightIndex] }

    /// Freezes the ring and places the opening highlight. Fails when there is nothing to switch
    /// between (fewer than two candidates) so the caller passes ⌃⇥ through instead of swallowing it
    /// into an overlay that cannot do anything.
    ///
    /// Forward opens at index 1 — the previous tab — because press-and-release with no repeat is the
    /// "flip to the last tab" gesture; opening at 0 would make the common case a no-op.
    public init?(candidates: [TabID], forward: Bool, armedByModifier: Bool) {
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

    /// Builds the frozen candidate order: the active tab, then recency, then anything never visited.
    ///
    /// - `active` leads even when it is not the ring's head. With device focus UNFOLLOWED this
    ///   device's active tab is its own, while `focusMRU` reflects whichever client last published a
    ///   focus — leading with the ring head there would make the first ⌃⇥ jump relative to somebody
    ///   else's cursor.
    /// - `mru` entries absent from `ordered` are dropped: the applier prunes the ring to live tabs,
    ///   but the client mirror can lag a close, and committing onto a dead tab stages a focus intent
    ///   naming a tab the host no longer has.
    /// - `ordered` (creation order) supplies both the fallback for a cold session whose ring is empty
    ///   and the tail of never-visited tabs, so every tab stays reachable.
    public static func candidates(active: TabID?, mru: [TabID], ordered: [TabID]) -> [TabID] {
        let live = Set(ordered)
        var seen = Set<TabID>()
        var result: [TabID] = []
        func append(_ id: TabID) {
            guard live.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }
        if let active { append(active) }
        for id in mru { append(id) }
        for id in ordered { append(id) }
        return result
    }
}
