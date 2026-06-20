#if canImport(SwiftUI)
import SwiftUI

// MARK: - CompletionBadge (the background-pane command-completion indicator — B3)

/// A small ✓ (green) / ✗ (red) glyph a tab / session row carries when a command finished on a
/// BACKGROUND pane while you were elsewhere (docs/42 B3). Mirrors ``AgentStatusDot``'s zero-cost
/// contract: a `nil` badge renders an EMPTY view (zero size) so a row with nothing pending stays clean.
///
/// `.success → ✓ green`, `.failure → ✗ red`. Pure presentation; the store's focus-gated
/// `handleCommandCompleted` feeds the rolled-up badge in (cleared the instant you focus the pane).
struct CompletionBadge: View {
    /// The rolled-up badge to render. `nil` ⇒ nothing.
    let badge: PaneCompletionBadge?
    /// The glyph point size (the sidebar uses a slightly larger badge than the tab pill).
    var size: CGFloat = 7

    var body: some View {
        if let badge {
            Image(systemName: Self.symbol(for: badge))
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Self.color(for: badge))
                .help(Self.label(for: badge))
                .accessibilityLabel(Text("command \(Self.label(for: badge))"))
        } else {
            // No pending completion: render nothing (zero size) so a clean row carries no badge.
            EmptyView()
        }
    }

    /// The SF Symbol name for `badge`.
    static func symbol(for badge: PaneCompletionBadge) -> String {
        switch badge {
        case .success: "checkmark"
        case .failure: "xmark"
        }
    }

    /// The glyph colour for `badge`.
    static func color(for badge: PaneCompletionBadge) -> Color {
        switch badge {
        case .success: .green
        case .failure: .red
        }
    }

    /// A short human label for the tooltip / accessibility.
    static func label(for badge: PaneCompletionBadge) -> String {
        switch badge {
        case .success: "succeeded"
        case .failure: "failed"
        }
    }
}
#endif
