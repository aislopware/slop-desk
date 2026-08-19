// PaneRecedeScrim — the "some OTHER pane is the subject right now" veil.
//
// WHY IT IS NOT A RESTING TREATMENT: dimming the unfocused panes permanently was tried and REMOVED — it
// washed out live content, and a pane you are watching a build in must not be half-erased because your
// cursor is elsewhere. Focus at rest is the small corner marker (`PaneFocusCorner`), which adds a mark to
// the subject instead of subtracting from everything else.
//
// A ⌃⇥ walk is the opposite case. For the length of a held modifier the whole point of the screen is
// "WHICH pane am I about to land on", the answer changes on every tap, and a corner marker 900px away is
// not something the eye finds in 200ms. So the contrast is turned up for exactly that moment and turned
// back down when the gesture ends. Transient, never resting.
//
// Lighter than ``PaneResizeScrim``: that one HIDES a stretched surface, this one RECEDES a legible one —
// the dimmed panes must stay readable, or the walk is a jump between blanks rather than a look.
//
// Purely decorative: the caller fades it in/out via `.opacity` (so the plate stays in the tree, cheap) and
// keeps it non-hit-testing — a click during a walk abandons the switcher and focuses the pane under the
// cursor, which is the right escape and must not be blocked. SYSTEM/DS colours only.

#if canImport(SwiftUI)
import SlopDeskSlate
import SwiftUI

struct PaneRecedeScrim: View {
    var body: some View {
        // The pane's own surface colour (`Slate.Surface.terminal`), so the veil is theme-directed by
        // construction: on a dark theme it sinks the content toward the background, on a light one it
        // washes it toward the paper. Either way the pane reads as a step BACK rather than a covered one.
        //
        // 0.72 is MEASURED, not picked: at 0.55 (the first try, photographed) a light theme's black text
        // only went mid-grey and the difference was there but not findable at a glance across a 1280pt
        // window, which is the one thing this has to be.
        Slate.Surface.terminal
            .opacity(0.72)
    }
}
#endif
