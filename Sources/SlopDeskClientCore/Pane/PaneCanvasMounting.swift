// PaneCanvasMounting — which tabs the canvas keeps MOUNTED, which is not the same question as which
// tab it shows.
//
// KEEP-ALL-MOUNTED is the canvas's load-bearing invariant: every tab of every retained session stays in
// the tree at `opacity(0)`, never unmounted, because unmounting a tab's subtree destroys its libghostty
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

import Foundation
import SlopDeskWorkspaceModel

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
}
