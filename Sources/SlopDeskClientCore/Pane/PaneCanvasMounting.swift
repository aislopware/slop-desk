// PaneCanvasMounting — which tabs the canvas keeps MOUNTED, which is not the same question as which
// tab it shows.
//
// KEEP-ALL-MOUNTED is the canvas's load-bearing invariant: every tab of every retained session stays in
// the tree at `opacity(0)`, never unmounted, because unmounting a tab's subtree destroys its terminal
// surface and its video session. A returning tab then has to be repainted from the replay ring, which
// is lossy — the regression it produced in the field was an unfocused pane losing its prompt. So the
// mounted SET is a correctness rule, not a performance tweak, and it was a computed property on a
// `some View`.
//
// The rule has three parts and each one is a separate near-miss:
//   • the RETAINED sessions (the LRU set behind an A→B→A switch) — without them a session switch
//     dismantles every outgoing surface, which is the tab-switch regression one level up;
//   • the ACTIVE session ALWAYS, even before the first switch, when the retention set is still empty;
//   • the INTERSECTION with what actually exists, so a retained id for a since-closed session is
//     dropped rather than mounted as a ghost.
//
// Order is session-then-tab-bar order, which is what keeps the `ForEach` identity stable across a
// retention change.

import CoreGraphics
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The "am I wired to the model" latch every mounted pane surface keeps.
///
/// An imperative shell arms its observation when the view enters a window and drops it when the view
/// leaves for good, and BOTH edges arrive repeatedly: `viewDidMoveToWindow` / `didMoveToWindow` fire on
/// every re-parent, a teardown can precede an unmount, a re-attach can follow a teardown, and a focus
/// push re-arms in the middle. So each edge has to be idempotent, and every surface had written the
/// same `guard` / set / act triple by hand.
///
/// IT ANSWERS RATHER THAN ACTING, which is what lets it be one type instead of two. What gets armed is
/// the shell's and cannot be named from here — an ``ObservationFollow`` on the Mac, a generation
/// counter on the phone until it converts — so the gate returns "yes, this is the edge that counts"
/// and the caller does the arming.
package struct PaneMountGate {
    private var isWired = false

    package init() {}

    /// Whether THIS attach is the one that should arm. `false` for a repeat.
    package mutating func attach() -> Bool {
        guard !isWired else { return false }
        isWired = true
        return true
    }

    /// Whether THIS detach is the one that should stop. `false` when nothing is armed.
    package mutating func detach() -> Bool {
        guard isWired else { return false }
        isWired = false
        return true
    }

    /// Whether something is armed right now — what a focus push asks before re-arming, since re-arming
    /// a surface that was never wired would observe on behalf of a view that is not on screen.
    package var isArmed: Bool { isWired }
}

/// Which of the workspace's tabs stay mounted in the canvas.
package enum PaneCanvasMounting {
    /// Every tab of every retained session plus the active one, in session-then-tab-bar order.
    package static func mountedTabs(
        sessions: [Session], retained: [SessionID], activeID: SessionID?,
    ) -> [Tab] {
        sessions
            .filter { retained.contains($0.id) || $0.id == activeID }
            .flatMap(\.tabs)
    }

    /// The FIRST half of a keyed reconcile: everything the model dropped leaves, and it TEARS DOWN
    /// BEFORE IT DETACHES (docs/62 §3.2).
    ///
    /// The order is the whole point and it is why this is a function rather than three lines written
    /// out at each of the four reconcile sites. A mounted pane owns a terminal surface, a video
    /// session and an observation arm; detaching the view first leaves that machinery running against a
    /// parent it no longer has, and the leak only shows up as a stuck decoder much later. Teardown
    /// first, detach second, forget third — always.
    ///
    /// Generic over the value because the four call sites mount four different things (tab layers, pane
    /// containers, dividers, move handles) and the RULE is about the dictionary, not the view: nothing
    /// here names a view type, and `teardown` is the caller's two framework lines.
    package static func drop<Key: Hashable, Value>(
        from mounted: inout [Key: Value], keeping wanted: Set<Key>, teardown: (Value) -> Void,
    ) {
        for (key, value) in mounted where !wanted.contains(key) {
            teardown(value)
            mounted[key] = nil
        }
    }

    /// Where ONE pane goes and what it is told about itself — the solved geometry plus the three flags
    /// a mounted pane surface reads, resolved in one pass.
    package struct PanePlacement {
        /// The pane this placement is about.
        package let id: PaneID
        /// The pane's frame in canvas-local coordinates, straight from the solver.
        package let rect: CGRect
        /// Whether the compositor is holding this pane off-screen (a zoom, a mid-move source).
        package let isHidden: Bool
        /// Whether this pane RENDERS focused — the workspace answer, already run through the code
        /// sidebar's keyboard claim.
        package let isFocused: Bool
        /// Whether this pane is on screen at all: its tab is the active one AND it is not held hidden.
        package let isVisible: Bool
    }

    /// Resolve every leaf of `tab` into a ``PanePlacement``.
    ///
    /// Three separate rules meet here and each was written out inline in both shells:
    ///   • FOCUS is never the tab's own answer alone. A background tab still carries an `activePane`,
    ///     so ``PaneFocusPolicy/isPaneFocused(_:in:activeTabID:)`` gates on the tab being active, and a
    ///     hidden leaf never claims it either.
    ///   • The code sidebar can hold the keyboard over the whole workspace, so the workspace answer is
    ///     then filtered through ``CodeSidebarKeyboardState``'s `paneRendersFocused` rule.
    ///   • VISIBILITY is the tab's, not the pane's: every pane of a mounted-but-inactive tab is
    ///     invisible no matter what the solver said about it (KEEP-ALL-MOUNTED).
    ///
    /// ⚠️ This reads ``CodeSidebarKeyboardState/shared`` and ``WorkspaceStore/tree``, and it runs from
    /// LAYOUT — outside the observation-tracking closure. Both shells must keep reading those two in
    /// their own `follow` read-block, or a sidebar focus flip will not schedule a relayout.
    @MainActor
    package static func place(
        _ entries: [SplitTreeRenderModel.CompositorLeaf],
        tab: Tab,
        store: WorkspaceStore,
        tabIsActive: Bool,
    ) -> [PanePlacement] {
        let activeTabID = store.tree.activeSession?.activeTab?.id
        let sidebarOwnsKeyboard = CodeSidebarKeyboardState.shared.ownsKeyboard
        return entries.map { entry in
            let focused = CodeSidebarKeyboardState.paneRendersFocused(
                workspaceFocused: !entry.isHidden
                    && PaneFocusPolicy.isPaneFocused(entry.id, in: tab, activeTabID: activeTabID),
                sidebarOwnsKeyboard: sidebarOwnsKeyboard,
            )
            return PanePlacement(
                id: entry.id,
                rect: entry.leaf.rect,
                isHidden: entry.isHidden,
                isFocused: focused,
                isVisible: tabIsActive && !entry.isHidden,
            )
        }
    }
}
