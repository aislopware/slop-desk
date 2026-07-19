// SlateEmptyState — the workspace empty-state voice (MERIDIAN C3). The pane area's "nothing here"
// states share ONE quiet composition — a muted symbol, a short title, a one-line cause, and (when
// there is one) the single next action — instead of the native `ContentUnavailableView`, whose voice
// and metrics sit outside the Slate system. The CAUSE is typed: each cause carries its own pinned
// copy + symbol (unit-tested), so call sites can't drift into ad-hoc wording, and the copy names the
// actual reason ("Not Connected" vs "Connection Lost" vs "No Open Tabs") rather than one generic
// "No Session" for all three.
//
// At-rest = zero ornament (the standing bar): plain text on the pane face, no card, no shadow; the
// only chrome is the action's raised plate — which IS the action, not decoration.

#if canImport(SwiftUI)
import SwiftUI

struct SlateEmptyState: View {
    /// WHY the surface is empty — each cause pins its own symbol/title/caption/action copy.
    enum Cause: Equatable {
        /// No host connected (fresh launch / disconnected) — the next action is the Connect editor.
        case neverConnected
        /// A host WAS reachable and the link is down — the supervisor is redialing on its own, so
        /// there is no action; the caption names the host being re-dialed.
        case linkDown(host: String)
        /// Connected fine — just no open tabs; the next action mints one.
        case noTabs
        /// The last explicit connect attempt failed — the caption carries the REAL reason (not the
        /// generic not-connected copy) so a wrong host/port reads as its own mistake, and the action
        /// reopens the Connect editor to correct it.
        case connectFailed(reason: String)
    }

    let cause: Cause
    /// Fires the cause's single next action (Connect editor / New Tab). Ignored when the cause has none.
    var onAction: () -> Void = {}

    @State private var hover = false

    // MARK: - Pinned copy (pure, unit-tested)

    static func symbol(for cause: Cause) -> String {
        switch cause {
        case .neverConnected: "bolt.horizontal"
        case .linkDown: "wifi.exclamationmark"
        case .noTabs: "terminal"
        case .connectFailed: "exclamationmark.triangle"
        }
    }

    static func title(for cause: Cause) -> String {
        switch cause {
        case .neverConnected: "Not Connected"
        case .linkDown: "Connection Lost"
        case .noTabs: "No Open Tabs"
        case .connectFailed: "Connect Failed"
        }
    }

    static func caption(for cause: Cause) -> String {
        switch cause {
        case .neverConnected: "Connect to a host to open a terminal."
        case let .linkDown(host): "Reconnecting to \(host)…"
        case .noTabs: "Open a tab to get started."
        case let .connectFailed(reason): reason
        }
    }

    /// The single next action's label, or `nil` when the cause has no user action (link-down redials
    /// itself — offering a button there would suggest the user must do something).
    static func actionLabel(for cause: Cause) -> String? {
        switch cause {
        case .neverConnected: "Connect to Host…"
        case .linkDown: nil
        case .noTabs: "New Tab"
        case .connectFailed: "Connect to Host…"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemName: Self.symbol(for: cause))
                .font(.system(size: Slate.Typeface.display, weight: .ultraLight))
                .foregroundStyle(Slate.Text.tertiary)
                .padding(.bottom, Slate.Metric.space1)
            Text(Self.title(for: cause))
                .font(.system(size: Slate.Typeface.body, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(Self.caption(for: cause))
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.secondary)
            if let label = Self.actionLabel(for: cause) {
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
