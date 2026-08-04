// SlateKit — small reusable chrome controls built on the polished `Slate` token layer (SlateDesign.swift):
//   • `PlateIconButton` — the hover-plate icon button: a borderless SF-Symbol button that grows a faint
//     rounded hover plate, 0.12s small-fade. Used by the titlebar + sidebar chrome.
//   • `HoverSensor` — a hit-test-TRANSPARENT hover tracker for the top-strip reveal choreography.

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
        .buttonStyle(SlatePlateStyle { background(pressed: $0) })
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

/// The plate idiom's fill, drawn by the BUTTON STYLE so it can see the press.
///
/// `.buttonStyle(.plain)` with the fill inside the label cannot: `isPressed` reaches a style and
/// nothing else, and the alternatives — a `DragGesture(minimumDistance: 0)` or a long-press sensor —
/// both take the events the row shells and scroll views underneath these buttons need.
struct SlatePlateStyle: ButtonStyle {
    /// The fill for the plate, asked once per press phase.
    let fill: (_ isPressed: Bool) -> Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                fill(configuration.isPressed), in: .rect(cornerRadius: Slate.Metric.radiusControl),
            )
            // Both directions through the same 120ms fade: a click shorter than that still shows,
            // because the release fades from wherever the press had reached.
            .animation(Slate.Anim.smallFade, value: configuration.isPressed)
    }
}

/// One right-panel TAB — a WORD on a plate, and deliberately no glyph.
///
/// THE MARKS ARE GONE (user-reported 2026-08-04, twice: the tabs read as four unrelated things, and
/// still did after the sizes were measured and corrected). The strip's four surfaces are a folder, an
/// Apple logo, a hand-drawn Android head and a screen — an outline, a tall narrow brand, a wide dome
/// and a wide rectangle. What the eye compares across a strip is optical MASS, and no size makes
/// those four agree on it: the second attempt equalised their ink to a 2.5pt band (`18527962`) and
/// the row still read ragged, because the band was never the problem. Words have no such spread —
/// four labels in one face at one size are the same height by construction — so the fix was to stop
/// asking the marks to line up and stop drawing them.
///
/// The glyphs cost nothing to lose. They were identifying four surfaces that also carry names, in a
/// panel where only one tab was ever expanded far enough to show its name; the labels now do the
/// identifying full time. This is the ordinary idiom for a panel's own tab strip (a browser's
/// inspector, a design tool's right rail) rather than an app-wide navigation rail, where icons earn
/// their place by surviving a collapse to a 24pt column. Nothing about this strip collapses.
///
/// What survives from the resurrected inspector tab (`InspectorColumn.tabButton`, deleted in
/// `6de70aa`, dug back up user-directed 2026-08-03 after two animation redesigns were rejected —
/// round 1's opacity fades read as cheap, round 2's width morph as stuttery) is the shape the user
/// named as the good one: a pill, filled when selected, flat when not. It no longer changes SIZE
/// between the two states, which is what those animation rounds were fighting over — every tab now
/// holds its own width and only the fill moves.
///
/// There are NO `.animation` modifiers on the selection path. The ONE animation there is the
/// caller's `withAnimation(Slate.Anim.standard)` transaction around the selection write, which
/// carries the fill and the surface swap in a single beat; do not re-add per-view animations. Hover
/// is a separate channel — it answers the pointer, not the selection — and fades on its own.
struct PanelTabPlate: View {
    let label: String
    let selected: Bool
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // MEDIUM when selected, REGULAR when not. Weight and ink carry the state together, which
            // is the same pair every other latched control in the app uses (``PlateIconButton``), and
            // the reason the plate can stay as faint as it is: three channels saying one thing.
            Text(label)
                .font(.system(
                    size: Slate.Typeface.footnote, weight: selected ? .medium : .regular,
                ))
                .foregroundStyle(selected ? Slate.Text.primary : Slate.Text.icon)
                .padding(.horizontal, Slate.Metric.space2)
                .frame(height: Slate.Metric.plate)
                .background(fill, in: .rect(cornerRadius: Slate.Metric.radiusControl))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }

    /// The plate rungs a latched control uses everywhere else: ``Slate/State/selected`` for on,
    /// ``Slate/State/hover`` for the pointer. The old tab sat its selected state on the HOVER tint,
    /// which is a rung too faint to be seen at true size once the glyph beside it stopped shouting —
    /// and it left the unselected tabs with no pointer feedback at all, which a word without a glyph
    /// cannot afford: a plate that never moves under the pointer does not read as a control.
    private var fill: Color {
        if selected { return Slate.State.selected }
        return hovering ? Slate.State.hover : .clear
    }
}

#if os(macOS)
import AppKit

/// An invisible, hit-test-TRANSPARENT hover sensor: `hitTest` returns nil so clicks, drags and the
/// window-move gesture pass through untouched — the tracking area still reports enter/exit. This is
/// what the top-strip reveal rides: chrome toggles hide at rest and appear only while the pointer is
/// in the top zone (the otty behavior). SwiftUI `.onHover` needs `.contentShape` over the transparent
/// strip, which would ALSO swallow those clicks; an NSView tracking area decouples "where hover is
/// sensed" from "what is clickable".
struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> SensorView {
        let view = SensorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: SensorView, context _: Context) {
        view.onChange = onChange
    }

    final class SensorView: NSView {
        var onChange: ((Bool) -> Void)?

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil,
            ))
        }

        override func mouseEntered(with _: NSEvent) { onChange?(true) }
        override func mouseExited(with _: NSEvent) { onChange?(false) }
    }
}
#endif
#endif
