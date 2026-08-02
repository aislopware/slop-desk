// ToastStackView — the transient in-app notification host. Renders the live ``OverlayCoordinator/toasts``
// stack as a bottom-trailing column (newest last, flush to the corner), the in-app surface for the
// background events that ALSO fire a macOS notification (long-command finished, agent-needs-input, pane
// events) — so a user watching the workspace sees them without leaving the window.
//
// A notification is A PANE SPEAKING FROM OFF-SCREEN. Every push site is gated on the source pane NOT being
// focused, so a card always names a place the user is not looking at — which is what the design answers:
//
//   * The card is a member of the FLOATING FAMILY (``SlateOverlayCard``): the same glass, the same neutral
//     system ink, sentence-case in one voice, hierarchy by size and weight. The previous design spoke the
//     instrument register — a coloured caps-mono EYEBROW (`DONE · Claude`) over a mono subject on an opaque
//     plate — and it was rejected wholesale the same week the form cards shed their caps-mono titles: four
//     hues of engraving stacked in a corner read as an instrument panel, not as an app speaking. The words
//     the eyebrow carried didn't die, they became the HEADLINE — a sentence-case event phrase ("Claude
//     needs input", "make check failed") resolved from source + flavour by ``headline(for:)``.
//   * The LEADING MARK speaks the system's enclosed-status idiom: the `*.circle.fill` two-layer form in
//     one hue — glyph at full strength on its own disc at the hierarchical layer opacity — with the
//     SF Symbols 7 gradient for dimension, drawn as its two symbol layers so the glyph is CENTRED on the
//     disc (the fused `info.circle.fill` sets its "i" visibly off-centre at this size). Leading with a
//     status mark is the native idiom (HIG banners, Linear, Sonner); the earlier hand-tinted flat wash
//     disc — and before it the solid monochrome `*.circle.fill` — were both photographed and read as
//     stickers laid ON the glass, because a hand-built fill does not participate in the material's
//     vibrancy the way a symbol does (HIG: symbols, not images, on glass). One glyph family, one size,
//     one weight — NOT the mixed-family outline quartet an earlier round cut. A routine notice's mark is
//     NEUTRAL — cyan on every OSC notice was chrome pretending to be signal. The surface itself is never
//     tinted by flavour and there is no coloured rail.
//   * The CARD IS A DOOR. Tapping it jumps to the pane it names (``Toast/paneKey`` → the mount site's
//     `jumpToPaneTree`, the same seam `ConnectionAlertChip` uses, breadcrumb cue included). A notification
//     about somewhere else that cannot take you there is a dead end.
//   * The DWELL PAUSES ON HOVER — a pointer resting on a card freezes its clock, so a notification can no
//     longer be yanked away mid-read. Nothing DRAWS the remaining time: a depleting hairline along the
//     bottom edge was built and cut for reading as ornament. The fix for "it vanished while I was reading"
//     is that it stops, not that it announces how long it has left.
//   * The SPINE. Only the newest ``ToastStackLayout/expandedCount`` cards carry a detail line; older ones
//     collapse to the headline row alone, so four simultaneous notifications cost a third of the
//     corner instead of blanketing the prompt. Hovering a collapsed row expands just it, and a row is
//     promoted as the cards below it expire — no information is stranded on any platform.
//   * The X IS HOVER-ONLY (always present on a sticky card, which has no other exit). Four permanent ✕
//     marching down the corner was chrome for something that leaves by itself.
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

    /// The status mark's ink for a toast flavour: success → OK, error → error, attention → WARN,
    /// default → info (the card itself renders a default-flavour mark NEUTRAL — see `markTint`).
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

    /// The HEADLINE — the sentence-case event phrase that leads the card, resolved from ``Toast/source``
    /// and ``Toast/flavor`` TOGETHER. Flavour alone cannot decide it: `.success` is "the agent finished
    /// its turn" for an agent and "the command exited 0" for a command, and those are two different
    /// speakers saying two different words. A toast may carry its own ``Toast/headline`` override when it
    /// knows a truer phrase than this derivation can reach. Pure + `static` for the same reason as
    /// ``tint(for:)``.
    static func headline(for toast: Toast) -> String {
        if let explicit = toast.headline, !explicit.isEmpty { return explicit }
        switch (toast.source, toast.flavor) {
        case (.agent, .attention): return "\(toast.title) needs input"
        case (.agent, .success): return "\(toast.title) is done"
        case (.agent, .error): return "\(toast.title) failed"
        case (.agent, .default): return "\(toast.title) is working"
        case (.command, .success): return "\(toast.title) finished"
        case (.command, .error): return "\(toast.title) failed"
        // A notice/advisory speaks its own words — the title IS the message (an OSC 9 program line, a
        // cwd advisory), and prefixing an event verb onto someone else's sentence garbles it.
        case (.command, .default),
             (.command, .attention): return toast.title
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
    /// Whether this card shows its detail line, or collapses to the headline row alone. Hovering
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
            .padding(.vertical, Slate.Metric.space3)
            // One uniform column edge — see `Slate.Metric.toastWidth` for why the cards do NOT hug.
            .frame(width: Slate.Metric.toastWidth, alignment: .leading)
            // The SAME glass every floating surface wears (rim + cast shadow included) — the toast was
            // the last opaque outlier of the family. No hit barrier: this card's whole body is already
            // its jump button, and a background barrier would swallow the very clicks it exists to take.
            .slateGlassCard(hitBarrier: false)
            // The hover flip must run inside `withAnimation`: expanding this card shifts every SIBLING
            // card in the stack, and a bare assignment animates only this subtree (the keyed `.animation`
            // below) while the siblings snap — the transaction is what carries the curve to the column.
            .onHover { inside in
                withAnimation(Slate.Anim.stackReflow) { hovering = inside }
            }
            // Body reveal / spine promotion resize the card AND reflow the stack — the column curve.
            .animation(Slate.Anim.stackReflow, value: showsBody)
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
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            leadingMark
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
                    // The HEADLINE speaks the event as a sentence-case phrase in the floating family's
                    // reading ink — hierarchy by size and weight in ONE voice, like every card title.
                    Text(ToastStackView.headline(for: toast))
                        .font(.system(size: Slate.Typeface.body, weight: .semibold))
                        .foregroundStyle(SlateOverlayInk.primary)
                        .lineLimit(1)
                        // A subject is usually a command line, where the informative ends are the program
                        // and its last argument — so a too-long one loses its MIDDLE, not its tail.
                        .truncationMode(.middle)

                    // The ✕ keeps its slot even while hidden: a card that changed WIDTH or reflowed its
                    // subject on hover would be worse than one that reserves the button's corner.
                    Spacer(minLength: Slate.Metric.space2)
                    closeButton
                        .opacity(showsClose ? 1 : 0)
                }
                if showsBody, let detail = toast.body, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(SlateOverlayInk.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// The disc a mark sits on — sized off the grid, a shade taller than the headline's cap height.
    private var discSize: CGFloat { Slate.Metric.space4 + Slate.Metric.space1 }

    /// The disc layer's share of the mark's hue — matched to what HIERARCHICAL rendering gives the
    /// enclosure layer of the system's own `*.circle.fill` status symbols (0.30, measured off a rendered
    /// `info.circle.fill`), so the composed mark below is indistinguishable from the native idiom. Not a
    /// taste knob: drift it and the mark stops matching the system's status marks.
    private static let discLayerOpacity = 0.30

    /// The card's one point of colour: the system's enclosed-status idiom — a `*.circle.fill` in
    /// hierarchical rendering with the SF Symbols 7 gradient — drawn as its two layers, a `circle.fill`
    /// disc under the bare glyph, instead of the fused symbol. Composed for CENTRING: the fused
    /// `info.circle.fill` sets its serif "i" measurably off the disc's centre (~1.2% of the diameter),
    /// which a 20pt mark makes visible; stacked, each glyph centres on its own bounding box. The flat
    /// hand-tinted wash disc this replaces was photographed and read as a sticker ON the glass — a
    /// symbol-drawn disc participates in vibrancy, and the gradient gives it the dimension the fused
    /// symbol had (HIG: symbols, not images, on glass).
    private var leadingMark: some View {
        ZStack {
            Image(systemSymbol: .circleFill)
                .font(.system(size: discSize))
                .foregroundStyle(markTint.opacity(Self.discLayerOpacity))
            // `footnote`/medium puts the glyph at ~0.55 of the disc — the proportion the fused symbol
            // draws its inner layer at (measured 0.58) — where the old bold `small` glyph floated lost.
            Image(systemSymbol: markSymbol)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(markTint)
        }
        .symbolColorRenderingMode(.gradient)
        .frame(width: discSize, height: discSize)
        // A disc has no baseline of its own — hang its CENTER just above the headline's baseline
        // so it optically centres on the cap height instead of floating high.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Slate.Metric.space1 }
    }

    /// One family of BARE glyphs, one weight — never the mixed-family quartet the old design cut. The
    /// disc supplies the enclosure, so the glyphs themselves stay unenclosed.
    private var markSymbol: SFSymbol {
        switch toast.flavor {
        case .success: .checkmark
        case .error: .xmark
        case .attention: .exclamationmark
        case .default: .info
        }
    }

    /// Status hues keep their meaning (green finish / amber question / red failure); a routine notice
    /// stays NEUTRAL — the old cyan on every OSC notice was chrome pretending to be signal.
    private var markTint: Color {
        switch toast.flavor {
        case .default: SlateOverlayInk.secondary
        default: ToastStackView.tint(for: toast.flavor)
        }
    }

    private var closeButton: some View {
        // A comfortable square target, sized off the 8pt grid rather than the glyph so it stays a
        // finger/pointer target at the headline's type size.
        let target = Slate.Metric.space3 + Slate.Metric.space2
        return Button(action: onDismiss) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(SlateOverlayInk.secondary)
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
