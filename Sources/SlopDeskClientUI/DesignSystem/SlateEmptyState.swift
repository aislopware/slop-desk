// SlateEmptyState — the workspace empty-state voice (MERIDIAN C3), PHONE HALF. The pane area's
// "nothing here" states share ONE quiet composition — a muted symbol, a short title, a one-line cause,
// and (when there is one) the single next action — instead of the native `ContentUnavailableView`,
// whose voice and metrics sit outside the Slate system.
//
// THE COPY IS NOT HERE ANY MORE. Each cause carries its own symbol, title, caption and action label on
// ``PaneEmptyCause`` itself (`SlopDeskClientCore`, pinned by `PaneEmptyCopyTests`), so this view and
// ``SlopDeskMacUI/MacSlateEmptyState`` cannot say two different things about the same connection. The
// four tables are `String`-valued, so they DESCENDED rather than being pinned as a cross-renderer pair
// — docs/56 §3's P6: only a table with a `Color` in it is stuck above `SlopDeskSlate`.
//
// At-rest = zero ornament (the standing bar): plain text on the pane face, no card, no shadow; the
// only chrome is the action's raised plate — which IS the action, not decoration.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI

struct SlateEmptyState: View {
    /// WHY the surface is empty. The cause is ``PaneEmptyCause``, one target down: it is a reading of
    /// the CONNECTION, not a view, and both renderers have to reach the same verdict from the same
    /// status. It was nested inside this `View` until increment 54, which is why it could not be
    /// reached from AppKit at all.
    let cause: PaneEmptyCause
    /// Fires the cause's single next action (Connect editor / New Tab). Ignored when the cause has none.
    var onAction: () -> Void = {}

    @State private var hover = false

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemName: cause.symbolName)
                .font(.system(size: Slate.Typeface.display, weight: .ultraLight))
                .foregroundStyle(Slate.Text.tertiary)
                .padding(.bottom, Slate.Metric.space1)
            Text(cause.title)
                .font(.system(size: Slate.Typeface.body, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(cause.caption)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.secondary)
            if let label = cause.actionLabel {
                Button(action: onAction) {
                    Text(label)
                        .font(.system(size: Slate.Typeface.base, weight: .medium))
                        .foregroundStyle(Slate.Text.primary)
                        .padding(.horizontal, Slate.Metric.space3)
                        .frame(height: Slate.Metric.heightBar)
                        .background(
                            hover ? Slate.State.hover : Slate.Surface.raised,
                            in: .rect(cornerRadius: Slate.Metric.radiusControl),
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .animation(Slate.Anim.smallFade, value: hover)
                .padding(.top, Slate.Metric.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
#endif
