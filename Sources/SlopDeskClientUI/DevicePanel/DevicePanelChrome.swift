#if os(macOS)
import SwiftUI

/// The drawing both device panels do around the picture: the empty stage, the caption under it, the
/// notice a list draws when it has no rows, and the delay before a veil admits that a stream is
/// late.
///
/// These are DESIGN decisions, not device ones, and each was made once and written down twice —
/// `docs/DECISIONS.md` records the reasoning for all four in the singular ("a scrim says something
/// is on top of the picture; there is no picture"), which is the tell. A panel that redraws its own
/// empty state is how one console ends up on `Slate.Surface.field` and the other on `raised` after
/// a design pass touches the file it happened to be looking at.
///
/// What stays with each panel is the NUMBER that was measured on its own device — the simulator's
/// 400 ms against a 0.09 s first keyframe, the bridge's 600 ms against 0.83 s — because those are
/// facts about two different pieces of hardware and merging them would throw away the measurement.
///
/// `@MainActor` because the `Slate` tokens it reads are — a colour is resolved against the running
/// appearance, so it is the main actor's to answer. That costs nothing here: every caller is a view
/// body.
@MainActor
enum DevicePanelChrome {
    /// The stage with no picture on it: OPAQUE, on the stage's own tone rather than a dimming scrim.
    /// A scrim says "something is on top of the picture"; there is no picture, and the truthful
    /// drawing is the stage itself, empty.
    static func veil(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: Slate.Metric.space2) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.field)
            .transition(.opacity)
    }

    /// The line under a veil's mark — secondary, footnote-sized, one line of explanation.
    static func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)
    }

    /// What a device LIST draws in place of rows: centred, secondary, filling the space the rows
    /// would have had.
    ///
    /// A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04) — the last-known devices are
    /// still the best information available, the report goes to the window's notification card like
    /// every other report these panels make, and two bespoke alert shapes in one panel was the thing
    /// being fixed. This is for a list that is genuinely empty, which is a different sentence.
    static func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.base))
            .foregroundStyle(Slate.Text.secondary)
            .multilineTextAlignment(.center)
            .padding(Slate.Metric.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the loading veil should be showing, late on the way up and immediate on the way down;
    /// `nil` when the wait was cancelled and the caller must not write anything.
    ///
    /// The asymmetry is the whole point, and it is why the views keep a copy of the model's loading
    /// state at all: `.task(id:)` cancels this the instant the model's state flips, so a pending
    /// veil for a stream that arrived in time never appears. Waiting on the way DOWN would leave
    /// grey over a picture that is already there.
    static func loadingVeilState(isAwaiting: Bool, after delay: Duration) async -> Bool? {
        guard isAwaiting else { return false }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return nil }
        return true
    }
}
#endif
