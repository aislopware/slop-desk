// ToastStackView — the transient in-app notification host (E2 / WI-4). Renders the live
// ``OverlayCoordinator/toasts`` stack as a bottom-trailing column of dismissible cards (newest last),
// the in-app surface for the background events that ALSO fire a macOS notification (long-command finished,
// agent-needs-input, pane events) — so a user watching the workspace sees them without leaving the window.
//
// Each card mirrors the macOS banner anatomy (notification.png): a leading flavour glyph, a bold title, an
// optional secondary body line, and a trailing X to dismiss — wrapped in the native floating-card shell
// (system Material body, `.separator` hairline, rounded corners, a soft drop shadow). The flavour tint
// follows the model's `Toast.Flavor`: success → green, error → red, default → blue, attention → the
// system accent.
//
// SEAM discipline: the view OWNS no state — every read goes through the coordinator (the single
// `@Observable` reducer) and its only mutations are `dismissToast(_:)` (the X button + the per-card
// auto-dismiss timer). Each card's `.task(id:)` honours `toast.autoDismiss` (nil ⇒ sticky, only the X
// closes it) and bails on cancellation so a card removed early (X / cap-eviction) never double-dismisses.
// The host is ALWAYS mounted (it renders nothing when `toasts` is empty) so an arriving toast animates in
// without a parent re-mount — there is no visibility flag gating it (unlike the palette / cheat sheet).
// NATIVE styling (system Material, semantic colors, system text styles). Shared `AislopdeskClientUI`
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
        VStack(alignment: .trailing, spacing: 8) {
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
        .padding(16)
        // Bottom-trailing: the stack grows UPWARD from the corner, newest card flush to the bottom. The empty
        // surrounding frame carries no background, so it stays transparent to hits when there are no cards.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Animate the insert/remove transitions off the toast-id list (the coordinator mutates `toasts`
        // outside a `withAnimation`, so the value-keyed `.animation` is what drives the diff).
        .animation(.easeOut(duration: 0.18), value: coordinator.toasts.map(\.id))
    }

    // MARK: - Card

    private func toastCard(_ toast: Toast) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toast.flavor.icon)
                .font(.body)
                .foregroundStyle(Self.tint(for: toast.flavor))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(toast.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = toast.body, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            Button {
                coordinator.dismissToast(toast.id)
            } label: {
                Image(systemSymbol: .xmark)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: cardWidth, alignment: .leading)
        // Native toast-card shell: system Material body + hairline `.separator` ring + a soft drop shadow.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1),
        )
        .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
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
    /// unit test without instantiating the view: success → green, error → red, attention → the system accent,
    /// default → blue. `@MainActor` kept for call-site/test source compatibility (all callers are MainActor).
    @MainActor
    static func tint(for flavor: Toast.Flavor) -> Color {
        switch flavor {
        case .success: .green
        case .error: .red
        case .attention: .accentColor
        case .default: .blue
        }
    }
}
#endif
