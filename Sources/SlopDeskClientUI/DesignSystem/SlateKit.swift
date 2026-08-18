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

// The `HoverSensor` tracking-area view lived here for the top-strip reveal choreography, which the
// chrome no longer has: the toggles stand where they stand (`WindowSidebarToggle`,
// `SlopDeskMacUI/MacPanelRail`), so nothing mounted it and no strip appears on hover.
//
// `PanelTabPlate` left with them — the right panel's four tabs are AppKit now
// (`SlopDeskMacUI/MacPanelTabPlate`), off the one reading in `SlopDeskClientCore/PanelTabs`.
#endif
