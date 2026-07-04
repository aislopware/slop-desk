// ToastStackView — the transient in-app notification host (E2 / WI-4). Renders the live
// ``OverlayCoordinator/toasts`` stack as a bottom-trailing column of dismissible cards (newest last),
// the in-app surface for the background events that ALSO fire a macOS notification (long-command finished,
// agent-needs-input, pane events) — so a user watching the workspace sees them without leaving the window.
//
// Each card mirrors the macOS banner anatomy (notification.png): a leading flavour glyph, a bold title, an
// optional secondary body line, and a trailing X to dismiss — wrapped in the shared floating-panel shell
// (`Slate.Surface.card` body, `Slate.Line.subtle` hairline, `Slate.Metric.radiusCard` corners, a soft drop
// shadow). The flavour tint follows the model's `Toast.Flavor`: success → `Slate.Status.ok`, error →
// `Slate.Status.err`, default → `Slate.Status.info`, attention → `Slate.State.accent`.
//
// SEAM discipline: the view OWNS no state — every read goes through the coordinator (the single
// `@Observable` reducer) and its only mutations are `dismissToast(_:)` (the X button + the per-card
// auto-dismiss timer). Each card's `.task(id:)` honours `toast.autoDismiss` (nil ⇒ sticky, only the X
// closes it) and bails on cancellation so a card removed early (X / cap-eviction) never double-dismisses.
// The host is ALWAYS mounted (it renders nothing when `toasts` is empty) so an arriving toast animates in
// without a parent re-mount — there is no visibility flag gating it (unlike the palette / cheat sheet).
// `Slate.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`). Shared `AislopdeskClientUI`
// view — compiles for iOS too (no AppKit / `NSEvent` here); the bottom-trailing ZStack overlay reads the
// same on both platforms.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

struct ToastStackView: View {
    /// The single overlay reducer — read-only here for `toasts`; the view's only mutation is `dismissToast`.
    let coordinator: OverlayCoordinator

    /// The fixed card width — a compact banner anchored in the bottom-trailing corner (the OS banner is wider,
    /// but an in-app toast reads as a small card, not a full-width sheet).
    private let cardWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .trailing, spacing: Slate.Metric.space2) {
            ForEach(coordinator.toasts) { toast in
                toastCard(toast)
                    .transition(.asymmetric(
                        // Insert: slide in from the trailing edge (the corner the stack hugs) + fade.
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        // Remove: fade out in place (the X / auto-dismiss path).
                        removal: .opacity,
                    ))
            }
        }
        .padding(Slate.Metric.space4)
        // Bottom-trailing: the stack grows UPWARD from the corner, newest card flush to the bottom. The empty
        // surrounding frame carries no background, so it stays transparent to hits when there are no cards.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Animate the insert/remove transitions off the toast-id list (the coordinator mutates `toasts`
        // outside a `withAnimation`, so the value-keyed `.animation` is what drives the diff).
        .animation(Slate.Anim.fadeSlideIn, value: coordinator.toasts.map(\.id))
    }

    // MARK: - Card

    private func toastCard(_ toast: Toast) -> some View {
        HStack(alignment: .top, spacing: Slate.Metric.space2) {
            Image(systemName: toast.flavor.icon)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Self.tint(for: toast.flavor))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(toast.title)
                    .font(.system(size: Slate.Typeface.body, weight: .semibold))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(2)
                if let detail = toast.body, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: Slate.Metric.space2)

            Button {
                coordinator.dismissToast(toast.id)
            } label: {
                Image(systemSymbol: .xmark)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
        .frame(width: cardWidth, alignment: .leading)
        .background(Slate.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .stroke(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .shadow(color: Slate.State.shadow, radius: 18, x: 0, y: 8)
        // Per-card auto-dismiss: sleep `toast.autoDismiss` then dismiss. A nil delay ⇒ sticky (no timer). The
        // `do/catch return` bails on cancellation (the card removed early by the X / cap-eviction) so a torn-
        // down card never fires a late dismiss. Keyed on `toast.id` (a same-id re-push reuses this card).
        .task(id: toast.id) {
            guard let delay = toast.autoDismiss else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            coordinator.dismissToast(toast.id)
        }
    }

    // MARK: - Flavour tint

    /// The accent role for a toast flavour (the leading glyph tint). Pure + `static` so it can be pinned by a
    /// unit test without instantiating the view: success → OK, error → error, attention → the active accent,
    /// default → info. `@MainActor` because the `Slate.*` token accessors read the runtime `ThemeStore`.
    @MainActor
    static func tint(for flavor: Toast.Flavor) -> Color {
        switch flavor {
        case .success: Slate.Status.ok
        case .error: Slate.Status.err
        case .attention: Slate.State.accent
        case .default: Slate.Status.info
        }
    }
}
#endif
