// ToastStackView — the transient in-app notification host. Renders the live ``OverlayCoordinator/toasts``
// stack as a bottom-trailing column (newest last, flush to the corner), the in-app surface for the
// background events that ALSO fire a macOS notification (long-command finished, agent-needs-input, pane
// events) — so a user watching the workspace sees them without leaving the window.
//
// A notification is A PANE SPEAKING FROM OFF-SCREEN. Every push site is gated on the source pane NOT being
// focused, so a card always names a place the user is not looking at — which is what the design answers:
//
//   * There is NO LEADING GLYPH. The event class is spoken by an EYEBROW — a caps micro-label in the
//     instrument voice, letterspaced with `instrumentTracking`, inked with the flavour hue — followed by
//     `·` and the subject on the same line. This is MERIDIAN L2 taken literally ("typography is the only
//     ornament"), and it is the DS's existing engraving treatment (`SlateRow`, `SlatePopover`,
//     `InstrumentChip`, `NavigatorColumn`), not a new device. Two earlier leading elements were cut: the
//     SF Symbol quartet (`bell` / `checkmark.circle` / `exclamationmark.triangle` / `asterisk` — four
//     glyphs from four families that never shared a stroke weight, and the very pictograms rounds 19–21
//     pulled off the rail), then the rail's own `StatusDotView` ring/dot, which is right in the sidebar's
//     narrow mark column but read as a tiny abstract speck where a notification wants something concrete. A coloured
//     caps word carries the same bit with far more legible ink — and with no glyph column, every line
//     starts on ONE left rail.
//   * COLOUR LIVES IN EXACTLY ONE PLACE — the eyebrow. The surface is never tinted by flavour (chromatic
//     spread is the v5 slop bar) and there is no coloured edge rail. A monogram identity plate was probed
//     as the leading element and rejected for the same reason: `SlateMonogram`'s per-identity hue would put
//     a SECOND colour system on the card, fighting the status hue and breaking the one-hue budget.
//   * The CARD IS A DOOR. Tapping it jumps to the pane it names (``Toast/paneKey`` → the mount site's
//     `jumpToPaneTree`, the same seam `ConnectionAlertChip` uses, breadcrumb cue included). A notification
//     about somewhere else that cannot take you there is a dead end.
//   * The DWELL PAUSES ON HOVER — a pointer resting on a card freezes its clock, so a notification can no
//     longer be yanked away mid-read. Nothing DRAWS the remaining time: a depleting hairline along the
//     bottom edge was built and cut for reading as ornament. The fix for "it vanished while I was reading"
//     is that it stops, not that it announces how long it has left.
//   * The SPINE. Only the newest ``ToastStackLayout/expandedCount`` cards carry a detail line; older ones
//     collapse to the eyebrow + subject row alone, so four simultaneous notifications cost a third of the
//     corner instead of blanketing the prompt. Hovering a collapsed row expands just it, and a row is
//     promoted as the cards below it expire — no information is stranded on any platform.
//   * The X IS HOVER-ONLY (always present on a sticky card, which has no other exit). Four permanent ✕
//     marching down the corner was chrome for something that leaves by itself.
//
// Typography is the INSTRUMENT voice (MERIDIAN L2): a body like `exit 1 · 42s` is a technical readout, and
// setting it in proportional system text was what made the stack read as a web toast pasted into a
// terminal app. The surface is `Slate.Surface.raised` — the rung ABOVE the pane, like every other floating
// chip; the old `Surface.face` fill was the exact tone of the terminal behind it, leaving a dark-on-dark
// shadow as the only thing separating card from content.
//
// SEAM discipline: the view OWNS no notification state — every read goes through the coordinator (the
// single `@Observable` reducer) and its only mutations are `dismissToast(_:)` (the X, the dwell, a jump)
// and the injected `onJump`. Per-card `@State` (hover, dwell spent) lives in ``ToastCardView`` so each
// card has its own, keyed on ``Toast/epoch`` so a same-id re-push RESTARTS the dwell instead of inheriting
// the dead card's nearly-elapsed timer. The host is ALWAYS mounted (it renders nothing when `toasts` is
// empty) so an arriving toast animates in without a parent re-mount.
//
// `Slate.*` tokens ONLY (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`); no springs
// anywhere (`Slate.Anim` is cubic-bezier only). Shared `SlopDeskClientUI` view —
// compiles for iOS too (no AppKit / `NSEvent` here; `.onHover` simply never fires there, which is why the
// X is unconditional on a sticky card).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

// MARK: - Stack layout (the pure spine rule)

/// How many of the stack's cards speak in full and how many collapse to the spine. Pure + `static` so the
/// rule is unit-pinnable without rendering.
enum ToastStackLayout {
    /// The newest N cards render with their detail line. TWO, not one: the common burst is a pair
    /// (a command finishes in one pane while an agent asks a question in another) and both deserve to be
    /// readable at a glance; beyond that the corner is more valuable than the third body.
    static let expandedCount = 2

    /// Whether the card at `index` of a `count`-deep stack speaks in full. The stack is newest-LAST, so
    /// the expanded ones are at the END — the cards flush to the corner the eye already goes to.
    static func isExpanded(index: Int, count: Int) -> Bool {
        index >= count - expandedCount
    }
}

// MARK: - Host

struct ToastStackView: View {
    /// The single overlay reducer — read-only here for `toasts`; the view's only mutation is `dismissToast`.
    let coordinator: OverlayCoordinator
    /// Jump to the pane a notification names (its ``Toast/paneKey``) — injected by the mount site, which
    /// owns the store. `nil` (previews / the render test) leaves cards as plain, non-interactive notices,
    /// so this view never needs a `WorkspaceStore` to render.
    var onJump: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: Slate.Metric.space2) {
            ForEach(Array(coordinator.toasts.enumerated()), id: \.element.id) { index, toast in
                ToastCardView(
                    toast: toast,
                    expanded: ToastStackLayout.isExpanded(index: index, count: coordinator.toasts.count),
                    onDismiss: { coordinator.dismissToast(toast.id) },
                    onJump: jumpAction(for: toast),
                )
                .transition(.asymmetric(
                    // Insert AND remove both travel through the trailing edge — the corner the stack hugs.
                    // The old removal was opacity-only, so a card in the middle vanished in place and the
                    // ones above it snapped down; sliding out the way it came keeps the column coherent.
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity),
                ))
            }
        }
        .padding(Slate.Metric.space4)
        // Bottom-trailing: the stack grows UPWARD from the corner, newest card flush to the bottom. The
        // empty surrounding frame carries no background, so it stays transparent when there are no cards.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Animate the insert/remove transitions off the toast-id list (the coordinator mutates `toasts`
        // outside a `withAnimation`, so the value-keyed `.animation` is what drives the diff). Keyed on the
        // ids ALONE: a dwell tick must not re-trigger the stack transition, only the card's own track.
        .animation(Slate.Anim.fadeSlideIn, value: coordinator.toasts.map(\.id))
    }

    /// The jump closure for a card, or `nil` when there is nowhere to go (no `paneKey`, or no injected
    /// `onJump`) — which is what makes the card render as a plain notice rather than a button.
    private func jumpAction(for toast: Toast) -> (() -> Void)? {
        guard let key = toast.paneKey, let onJump else { return nil }
        return { onJump(key) }
    }

    // MARK: - Flavour tint

    /// The eyebrow's ink for a toast flavour: success → OK, error → error, attention → WARN, default → info.
    ///
    /// `.attention` is AMBER, not the theme accent. Two reasons, and the first is parity: the rail already
    /// fixed this mapping — "green = an unread finish, **amber = a question waiting**, red = failed"
    /// (``StatusDot``) — so an agent waiting on a human must be the same colour here as it is on its own
    /// sidebar row, or the app contradicts itself about what amber means. The second is that the accent was
    /// not even distinguishable: every Monokai seed sets `info == accent`, so `.attention` (needs input, the
    /// highest-signal event) and `.default` (a routine OSC notice) rendered in the SAME cyan, which is the
    /// one pair that most needs to differ. Amber also leaves the accent free for its single job — active
    /// state — and spends the status quartet's unused fourth rung on the case it was minted for.
    ///
    /// Pure + `static` so it can be pinned by a unit test without instantiating the view. `@MainActor`
    /// because the `Slate.*` token accessors read the runtime `ThemeStore`.
    @MainActor
    static func tint(for flavor: Toast.Flavor) -> Color {
        switch flavor {
        case .success: Slate.Status.ok
        case .error: Slate.Status.err
        case .attention: Slate.Status.warn
        case .default: Slate.Status.info
        }
    }

    /// The EYEBROW — the caps micro-label that opens the card, resolved from ``Toast/source`` and
    /// ``Toast/flavor`` TOGETHER. Flavour alone cannot decide it: `.success` is "the agent finished its turn"
    /// for an agent and "the command exited 0" for a command, and those are two different speakers saying
    /// two different words. A toast may carry its own ``Toast/eyebrow`` when it knows a truer one than this
    /// derivation can reach. Pure + `static` for the same reason as ``tint(for:)``.
    static func eyebrow(for toast: Toast) -> String {
        if let explicit = toast.eyebrow, !explicit.isEmpty { return explicit }
        switch (toast.source, toast.flavor) {
        case (.agent, .attention): return "NEEDS INPUT"
        case (.agent, .success): return "DONE"
        case (.agent, .error): return "FAILED"
        case (.agent, .default): return "WORKING"
        case (.command, .success): return "FINISHED"
        case (.command, .error): return "FAILED"
        // An advisory, not an alarm: the one command-flavour that asks the user to NOTICE something without
        // anything having gone wrong (a host-resolved cwd that may not exist there).
        case (.command, .attention): return "ADVISORY"
        case (.command, .default): return "NOTICE"
        }
    }
}

// MARK: - Card

/// One notification. A `View` (not a `func` on the host) so each card owns its OWN hover + dwell `@State`
/// — the previous `func`-built card could not, which is why the dwell lived in a bare `Task.sleep` with no
/// pause and no progress to show.
///
/// Internal rather than file-private, and its `hovering` state SEEDABLE, purely so a headless renderer can
/// photograph the hovered card: `ImageRenderer` never delivers a hover, so without the seed the ✕ and the
/// expanded spine row could not be captured at all. See `ToastStateGalleryTests`. The parameter defaults to
/// the real at-rest value, so no shipping call site passes it.
struct ToastCardView: View {
    let toast: Toast
    /// Whether this card shows its detail line, or collapses to the eyebrow + subject row alone. Hovering
    /// expands a collapsed card regardless (macOS only — `.onHover` never fires on iOS).
    let expanded: Bool
    let onDismiss: () -> Void
    /// `nil` ⇒ nowhere to jump; the card then renders as a plain notice instead of a button.
    let onJump: (() -> Void)?

    @State private var hovering: Bool
    /// Dwell CONSUMED, in seconds. Advanced by the tick loop below; frozen while `hovering`. Nothing renders
    /// it — it exists so the countdown can be PAUSED, which a single `Task.sleep` could not express.
    @State private var spent: Double = 0

    init(
        toast: Toast,
        expanded: Bool,
        onDismiss: @escaping () -> Void,
        onJump: (() -> Void)? = nil,
        hovering: Bool = false,
    ) {
        self.toast = toast
        self.expanded = expanded
        self.onDismiss = onDismiss
        self.onJump = onJump
        _hovering = State(initialValue: hovering)
    }

    /// The dwell SAMPLE interval — the granularity at which a hover can freeze the countdown. 10 Hz is
    /// imperceptible as a rounding error on a 4s dwell and costs nothing; it only runs while a card is
    /// actually on screen.
    private static let tick: Double = 0.1

    /// The whole dwell in seconds; 0 for a sticky card (no timer at all).
    private var total: Double { toast.autoDismiss.map(Self.seconds) ?? 0 }

    /// A collapsed card shows only its title; hovering it reveals the body it was holding back.
    private var showsBody: Bool { expanded || hovering }

    /// Hover-only, because a card that leaves by itself does not need permanent dismiss chrome — EXCEPT on
    /// a sticky card, whose only exit this is (and iOS has no hover to reveal it with).
    private var showsClose: Bool { hovering || toast.autoDismiss == nil }

    var body: some View {
        content
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, Slate.Metric.space2)
            // One uniform column edge — see `Slate.Metric.toastWidth` for why the cards do NOT hug.
            .frame(width: Slate.Metric.toastWidth, alignment: .leading)
            .slateCard(radius: Slate.Metric.radiusPanel)
            // Lift it off the pane. The `raised` fill + hairline do the real separating (MERIDIAN L5:
            // depth by light, not lines); the shadow is a soft assist, not the structure.
            .shadow(color: Slate.State.shadow, radius: Slate.Metric.space2, y: Slate.Metric.space1)
            .onHover { hovering = $0 }
            // Body reveal / spine promotion resize the card — a relayout, so the standard curve.
            .animation(Slate.Anim.standard, value: showsBody)
            .animation(Slate.Anim.smallFade, value: showsClose)
            .contentShape(Rectangle())
            .modifier(ToastJumpAction(onJump: onJump, title: toast.title))
            // The dwell. It spends `spent` up to `total` and then closes — but does NOT advance while
            // `hovering`, and THAT is the whole point: a pointer resting on a card freezes its clock, so a
            // notification can no longer be yanked away mid-read. Nothing about this is drawn (an earlier
            // round put a depleting hairline along the bottom edge to show the time left; it was cut for
            // reading as ornament — the pause is behaviour, not decoration). A plain `Task.sleep(total)`
            // cannot express it, which is why the countdown is sampled. Keyed on `epoch`, not `id`, so a
            // same-id re-push restarts from full instead of inheriting the replaced card's spent dwell.
            .task(id: toast.epoch) {
                spent = 0
                guard total > 0 else { return }
                while spent < total {
                    do { try await Task.sleep(for: .seconds(Self.tick)) } catch { return }
                    guard !hovering else { continue }
                    spent = min(total, spent + Self.tick)
                }
                onDismiss()
            }
    }

    // MARK: Pieces

    private var content: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space1) {
                // The EYEBROW carries the event class in the flavour ink — the card's only colour, and the
                // replacement for the leading rail mark. Caps + `instrumentTracking` is the DS's existing
                // engraving treatment (`SlateRow`, `SlatePopover`, `InstrumentChip`).
                Text(ToastStackView.eyebrow(for: toast))
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                    .tracking(Slate.Typeface.instrumentTracking)
                    .foregroundStyle(ToastStackView.tint(for: toast.flavor))
                    .fixedSize()
                Text("·")
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                Text(toast.title)
                    .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    // A subject is usually a command line, where the informative ends are the program and
                    // its last argument — so a too-long one loses its MIDDLE, not its tail.
                    .truncationMode(.middle)

                // The ✕ keeps its slot even while hidden: a card that changed WIDTH or reflowed its subject
                // on hover would be worse than one that reserves the button's corner.
                Spacer(minLength: Slate.Metric.space2)
                closeButton
                    .opacity(showsClose ? 1 : 0)
            }
            if showsBody, let detail = toast.body, !detail.isEmpty {
                Text(detail)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var closeButton: some View {
        // A comfortable square target, sized off the 8pt grid rather than the glyph so it stays a
        // finger/pointer target at the eyebrow's 10pt type size.
        let target = Slate.Metric.space3 + Slate.Metric.space2
        return Button(action: onDismiss) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(Slate.Text.secondary)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss notification")
        // Hidden ⇒ not a target, so a stray click in the corner cannot silently kill a card the user
        // never saw a ✕ on.
        .allowsHitTesting(showsClose)
    }

    /// `Duration` → seconds as a `Double`. Manual (no `TimeInterval` bridge) because `Duration` exposes
    /// only the component pair.
    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

// MARK: - Jump action

/// Makes the card a BUTTON when it has somewhere to go, and leaves it inert when it does not. A
/// `ViewModifier` rather than an `if` in `body` so both branches keep the same view identity — an `if`
/// there would re-mount the card (and reset its dwell `@State`) if a toast ever gained or lost its
/// `paneKey` under a same-id replace.
private struct ToastJumpAction: ViewModifier {
    let onJump: (() -> Void)?
    let title: String

    func body(content: Content) -> some View {
        if let onJump {
            Button(action: onJump) { content }
                .buttonStyle(.plain)
                .accessibilityHint("Jump to the pane this notification came from")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
        }
    }
}
#endif
