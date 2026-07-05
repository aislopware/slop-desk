// ConfirmFlashButton — a plain button that flashes a transient CONFIRMED state after firing.
//
// Silent one-shot actions (Copy Path / Copy Session ID / Copy Output) gave no visual acknowledgement, so
// a click felt like a no-op. This wrapper runs the action, then hands the label builder `confirming: true`
// for a short beat (the call site typically swaps its icon to a checkmark and tints `Slate.Status.ok`)
// before settling back. Re-clicks restart the beat cleanly: the beat rides `.task(id: generation)`, so a
// new click cancels the previous sleep instead of letting a stale reset cut the fresh flash short.
//
// Always `.plain` button style (the in-window Slate idiom); the label builder owns all chrome.

#if canImport(SwiftUI)
import SwiftUI

struct ConfirmFlashButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ confirming: Bool) -> Label

    /// Bumped per click — the `.task(id:)` key, so a re-click cancels the pending reset and re-arms it.
    @State private var generation = 0
    @State private var confirming = false

    var body: some View {
        Button {
            action()
            generation += 1
            withAnimation(Slate.Anim.smallFade) { confirming = true }
        } label: {
            label(confirming)
        }
        .buttonStyle(.plain)
        .task(id: generation) {
            guard generation > 0 else { return } // mount fires the task once with no click behind it
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(Slate.Anim.smallFade) { confirming = false }
        }
    }
}
#endif
