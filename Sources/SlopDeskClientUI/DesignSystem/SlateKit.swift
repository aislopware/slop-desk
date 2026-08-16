// SlateKit — small reusable chrome controls built on the polished `Slate` token layer (SlateDesign.swift):
//   • `PlateIconButton` — the hover-plate icon button: a borderless SF-Symbol button that grows a faint
//     rounded hover plate, 0.12s small-fade. Used by the titlebar + sidebar chrome.
//   • `slateGlyphAck(_:)` — THE acknowledgement every chrome button gives a click. One definition.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A hover-plate icon button — a borderless SF-Symbol with a faint rounded hover plate (radius 6).
struct PlateIconButton: View {
    let symbol: SFSymbol
    var size: CGFloat = Slate.Metric.iconSize
    var plate: CGFloat = Slate.Metric.plate
    /// A LATCHED state — the thing this button turns on is currently on. Distinct from hover, which
    /// is about the pointer: an active plate keeps its fill with the pointer elsewhere, and draws its
    /// glyph in the primary ink at a heavier weight so the state survives on a theme whose hover tint
    /// is faint.
    var active = false
    /// The state this button's verb LANDS ON, for a button that LATCHES something. Handing it over
    /// moves the acknowledgement from the press to the landing, which is what lets a chord or a menu
    /// row driving the same flag read exactly like a click on the plate. `nil` — a plain verb — still
    /// acknowledges: it just fires on the press instead (``SlatePlateStyle``).
    var morphOn: Bool?
    var action: () -> Void = {}

    @State private var hovering = false
    /// Set by ``SlatePlateGroup`` — a plate sitting on a tray shares the tray's fill, so both of its
    /// states step up a rung to stay visible against it.
    @Environment(\.slateOnPlateTray) private var onTray

    var body: some View {
        Button(action: action) {
            // MEDIUM at rest, matching ``SlatePlateButton`` — the two plate idioms drew the same
            // glyphs at two weights, and at 13pt an SF Symbol in the regular weight goes wispy
            // against a light theme's paper. One weight, so a plate is a plate wherever it is
            // mounted; SEMIBOLD is the one step above it, and it means latched.
            //
            // Latched is INK AND WEIGHT, never the accent (user-directed 2026-08-04). A blue glyph
            // is a hue carrying state, which is the pattern this app reversed on 07-30 and again
            // across the simulator panel; primary ink one weight up says the same thing in the two
            // channels that work on any theme, and reads as "on" rather than as "special".
            Image(systemSymbol: symbol)
                .font(.system(size: size, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Slate.Text.primary : Slate.Text.icon)
                .frame(width: plate, height: plate)
                .contentShape(.rect)
        }
        // The glyph's acknowledgement is the STYLE's, not this view's (user-directed 2026-08-09):
        // one effect, defined once, so every plate in the app answers a click the same way.
        .buttonStyle(SlatePlateStyle(landsOn: morphOn) { background(pressed: $0) })
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        // The LATCH, animated like the hover it sits above. Without this a toggle snapped between
        // two fills while the pointer that flipped it faded smoothly — one control, two speeds.
        .animation(Slate.Anim.smallFade, value: active)
    }

    /// Loose: hover fills faintly, latched sits on the selection tint. On a tray both move up —
    /// latched becomes a REAL raised surface, which is the only fill that still reads as "this one is
    /// on" when its neighbours are already carrying the tray's own tint.
    ///
    /// A PRESS moves the plate one rung in the direction the click is about to take it: a loose plate
    /// lights toward "on", a latched one drops toward "off". Every verb on these plates acts on a
    /// remote device, so the only other acknowledgement is the device itself changing a round trip
    /// later — and a key that does not move under the pointer reads as one that missed the click.
    private func background(pressed: Bool) -> Color {
        // XOR: pressing previews the latch state the click lands on.
        if active != pressed { return onTray ? Slate.Surface.raised : Slate.State.selected }
        if !hovering, !pressed { return .clear }
        return onTray ? Slate.State.selected : Slate.State.hover
    }
}

extension View {
    /// THE ACKNOWLEDGEMENT — the one thing a glyph does to say a click arrived (user-directed
    /// 2026-08-09). It was the sidebar toggle's alone; it is now the app's, defined here and nowhere
    /// else, so a device verb, a reload plate and a panel tab all answer in the same voice.
    ///
    /// A short symbol bounce, DOWNWARD, because a key that takes a click goes in before it comes
    /// back. Nothing translates and nothing changes size: the control is a fixed landmark and what
    /// changed is the thing it acts on, not the button (the same rule that moved the sidebar toggle
    /// to the window root). Every change of `trigger` plays it once — pass a counter for a plain
    /// verb, or the flag a latching control lands on so a chord fires it too.
    func slateGlyphAck(_ trigger: some Equatable) -> some View {
        symbolEffect(.bounce.down, options: .speed(Slate.Anim.ackSpeed), value: trigger)
    }
}

/// The plate idiom's fill AND its acknowledgement, drawn by the BUTTON STYLE so it can see the press.
///
/// `.buttonStyle(.plain)` with the fill inside the label cannot: `isPressed` reaches a style and
/// nothing else, and the alternatives — a `DragGesture(minimumDistance: 0)` or a long-press sensor —
/// both take the events the row shells and scroll views underneath these buttons need. Putting the
/// glyph bounce here as well is what makes it universal for free: every plate in the app already
/// wears this style, so none of them has to remember to ask for the effect.
struct SlatePlateStyle: ButtonStyle {
    /// The state a LATCHING button's verb lands on — see ``PlateIconButton/morphOn``. `nil` (a plain
    /// verb, which is most of them) acknowledges the PRESS instead.
    var landsOn: Bool?
    /// The fill for the plate, asked once per press phase.
    let fill: (_ isPressed: Bool) -> Color

    func makeBody(configuration: Configuration) -> some View {
        // A `ButtonStyle` has no storage of its own, and the acknowledgement needs a counter to
        // advance — so the body is a real view.
        Plate(configuration: configuration, landsOn: landsOn, fill: fill)
    }

    private struct Plate: View {
        let configuration: Configuration
        let landsOn: Bool?
        let fill: (Bool) -> Color

        /// Advanced by whichever edge this button acknowledges — see ``slateGlyphAck(_:)``.
        @State private var ack = 0

        var body: some View {
            configuration.label
                .slateGlyphAck(ack)
                .background(
                    fill(configuration.isPressed),
                    in: .rect(cornerRadius: Slate.Metric.radiusControl),
                )
                // Both directions through the same 120ms fade: a click shorter than that still
                // shows, because the release fades from wherever the press had reached.
                .animation(Slate.Anim.smallFade, value: configuration.isPressed)
                // A plain verb answers the press DOWN — its real effect is a round trip away, and a
                // key that waits for the reply reads as one that missed the click.
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard landsOn == nil, pressed else { return }
                    ack &+= 1
                }
                // A LATCHING button answers the landing instead, so the plate and a chord driving
                // the same flag are indistinguishable. `nil` maps to a constant and never fires.
                .onChange(of: landsOn ?? false) { _, _ in ack &+= 1 }
        }
    }
}

/// One right-panel TAB — a mark AND its name on a plate.
///
/// BOTH, on every tab, is the point. The strip spent two rounds with marks alone on the unselected
/// tabs and read ragged both times (user-reported 2026-08-04): a folder outline, a narrow solid
/// logo, a wide solid dome and a wide screen have no optical mass in common, and equalising their
/// ink to a 2.5pt band did not help, because ink height was never what the eye was comparing. A word
/// beside each mark settles it without touching the marks at all — the labels are the same height by
/// construction, and they push the marks far enough apart that no two of them are read against each
/// other. Marks alone were then tried and the strip lost too much (user-directed 2026-08-05).
///
/// So the mark identifies and the word names, and a tab that has room shows both. When the panel is
/// dragged narrow it has to give something up rather than truncate a word into nonsense — see the
/// caller's `ViewThatFits` ladder, which drops the labels the strip cannot afford. ``showsLabel`` is
/// how a rung of that ladder is asked for; nothing else should set it.
///
/// The pill is the resurrected inspector tab's (`InspectorColumn.tabButton`, deleted in `6de70aa`,
/// dug back up user-directed 2026-08-03 after two animation redesigns were rejected — round 1's
/// opacity fades read as cheap, round 2's width morph as stuttery), and the shape the user named as
/// the good one: filled when selected, flat when not. At full width it no longer changes SIZE
/// between states, which is what those animation rounds were fighting over.
///
/// There are still NO `.animation` modifiers on the selection path, and the two REJECTED rounds stay
/// rejected: round 1's opacity fades read as cheap, round 2's width morph as stuttery. What the plate
/// now takes instead is the sidebar's ``SlateCompactIsland/morph`` — supply a namespace and the ONE
/// selected plate TRAVELS from the old tab to the new one (user-directed 2026-08-09, after the
/// sidebar and the horizontal strip got the same treatment and this strip was the odd one left
/// jumping). That is neither of the rejected shapes: nothing fades, and nothing changes WIDTH — the
/// plate keeps the size the ladder's current rung gives it and only moves. The travel still rides the
/// caller's own `withAnimation` transaction, exactly as before; the namespace only says which plates
/// are the same plate. Hover is a separate channel — it answers the pointer, not the selection — and
/// fades on its own.
struct PanelTabPlate: View {
    /// What a tab draws before its label.
    ///
    /// The split is NOT between a shape and a brand. `apple.logo` is a brand and takes the same em as
    /// `folder`, because Apple's optical grid already makes them agree. The split is between a symbol
    /// on that grid and the one mark no icon set ships, which is a drawn path with no grid behind it
    /// and therefore the only one carrying its own size (``Slate/Metric/androidMark``).
    enum Mark {
        case symbol(SFSymbol)
        case android
    }

    let mark: Mark
    let label: String
    let selected: Bool
    /// False collapses the tab to a square cell holding only its mark — the narrow-panel rung.
    var showsLabel = true
    /// True lets the plate take whatever length its caller frames it to, instead of hugging its
    /// label. The panel's RAIL wants this — a column of tabs each as long as its own word reads as a
    /// ragged list, where a strip of tabs side by side reads fine hugging. Off everywhere else, so
    /// the strip's width ladder keeps reporting honest ideal widths.
    var spans = false
    /// How far the caller has turned the WHOLE plate, so the mark can turn back and stay upright.
    ///
    /// A word on its side is still read — the eye tilts and the letters keep their order. A GLYPH on
    /// its side is a different glyph: a rotated `folder` reads as a shape rather than as a folder,
    /// and Apple's own optical grid stops meaning anything (user-directed 2026-08-09). So the panel's
    /// rail turns the plate and hands the angle over; the mark takes it back out.
    var plateRotation: Angle = .zero
    /// The morph namespace shared by ONE strip of tabs — see ``SlateCompactIsland/morph``. `nil`
    /// keeps the plain fade for any caller mounting a lone plate.
    var morph: Namespace.ID?
    var action: () -> Void = {}

    @State private var hovering = false
    /// Advanced when this tab becomes THE selected one — see ``slateGlyphAck(_:)``. On selection,
    /// not on the press: a tab's verb lands on "this surface is showing", and the plate travelling
    /// here is the other half of the same answer.
    @State private var ack = 0

    init(
        mark: Mark, label: String, selected: Bool, showsLabel: Bool = true, spans: Bool = false,
        plateRotation: Angle = .zero, morph: Namespace.ID? = nil,
        action: @escaping () -> Void = {},
    ) {
        self.mark = mark
        self.label = label
        self.selected = selected
        self.showsLabel = showsLabel
        self.spans = spans
        self.plateRotation = plateRotation
        self.morph = morph
        self.action = action
    }

    init(
        symbol: SFSymbol, label: String, selected: Bool, showsLabel: Bool = true,
        spans: Bool = false, plateRotation: Angle = .zero, morph: Namespace.ID? = nil,
        action: @escaping () -> Void = {},
    ) {
        self.init(
            mark: .symbol(symbol), label: label, selected: selected, showsLabel: showsLabel,
            spans: spans, plateRotation: plateRotation, morph: morph, action: action,
        )
    }

    /// The SELECTED tab is a COMPACT ISLAND, the same chip the sidebar tab rows wear (user-directed
    /// 2026-08-08): the panel's four surfaces are tabs, so they answer "which one" in the window's
    /// one material rather than in an accent wash of their own.
    var body: some View {
        Button(action: action) {
            SlateCompactIsland(selected: selected, hovering: hovering, morph: morph) {
                plate
                    .foregroundStyle(selected ? Slate.Text.primary : Slate.Text.icon)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        // The app's one acknowledgement, on the tab that WINS — the tab losing selection has nothing
        // to acknowledge, and bouncing both would read as two events for one click.
        .onChange(of: selected) { _, now in
            guard now else { return }
            ack &+= 1
        }
    }

    @ViewBuilder
    private var plate: some View {
        if showsLabel {
            HStack(spacing: Slate.Metric.space1) {
                glyph
                // MEDIUM when selected, REGULAR when not — weight and ink carrying the state
                // together, the same pair every other latched control uses (``PlateIconButton``).
                // FIXED horizontally so the tab reports an honest ideal width: inside a
                // `ViewThatFits` a compressible label would let the widest rung "fit" by
                // truncating itself, which is the one outcome the ladder exists to avoid.
                Text(label)
                    .font(.system(
                        size: Slate.Typeface.footnote, weight: selected ? .medium : .regular,
                    ))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(maxWidth: spans ? .infinity : nil, alignment: .leading)
            .frame(height: Slate.Metric.plate)
        } else {
            // A SQUARE cell, not a plate hugging its mark: the marks are 10 to 17 points across, so
            // hugging gives four different widths and a row of ragged gaps. This square is also
            // exactly the cell ``PlateIconButton`` occupies at the other end of the same strip.
            glyph.frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
        }
    }

    /// Symbols take the strip's ICON measure (``Slate/Metric/iconSize``) — the one the action plates
    /// at the other end of the strip already use, and not the label's type size. A glyph and a word
    /// are not the same kind of thing, and sizing both from `footnote` had the tabs drawing at 11
    /// while the reload button beside them drew at 13.
    ///
    /// It is also the tab's ACKNOWLEDGEMENT surface (``slateGlyphAck(_:)``) — the mark is the part of
    /// a tab that can move without the tab moving.
    private var glyph: some View {
        markBody
            // Turned back out of whatever the caller turned the plate into, about its own centre, so
            // an upright mark sits in a plate lying on its side. `.rotationEffect` is a draw-time
            // transform: the cell the mark occupies is unchanged, and the four rail tabs keep the
            // same measure they have in the strip.
            .rotationEffect(-plateRotation)
            .slateGlyphAck(ack)
    }

    @ViewBuilder
    private var markBody: some View {
        switch mark {
        case let .symbol(symbol):
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
        case .android:
            AndroidRobotMark(side: Slate.Metric.androidMark)
        }
    }
}

// The `HoverSensor` tracking-area view lived here for the top-strip reveal choreography, which the
// chrome no longer has: the toggles stand where they stand (`WindowSidebarToggle`, `PanelRail`), so
// nothing mounted it and no strip appears on hover.
#endif
