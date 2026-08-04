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
                .background(background, in: .rect(cornerRadius: Slate.Metric.radiusControl))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }

    /// Loose: hover fills faintly, latched sits on the selection tint. On a tray both move up —
    /// latched becomes a REAL raised surface, which is the only fill that still reads as "this one is
    /// on" when its neighbours are already carrying the tray's own tint.
    private var background: Color {
        if active { return onTray ? Slate.Surface.raised : Slate.State.selected }
        if !hovering { return .clear }
        return onTray ? Slate.State.selected : Slate.State.hover
    }
}

/// One right-panel TAB plate — the pre-removal inspector's Details-bar tab, resurrected VERBATIM
/// (`InspectorColumn.tabButton`, deleted in `6de70aa`, dug back up user-directed 2026-08-03 after
/// two animation redesigns of the interim plate were both rejected — round 1's opacity fades read
/// as cheap, round 2's pure width morph read as stuttery; the user named THIS form as the good
/// one). Its shape: active = icon + label pill on the HOVER tint, inactive = icon only, NO hover
/// state of its own, and NO `.animation` modifiers — the ONE animation is the caller's
/// `withAnimation(Slate.Anim.standard)` transaction around the selection write, which carries the
/// plate relayout and the surface swap in a single coherent beat. Do not re-add per-view
/// animations here.
struct PanelTabPlate: View {
    let symbol: SFSymbol
    let label: String
    let selected: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemSymbol: symbol)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                if selected {
                    Text(label)
                        .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                }
            }
            .foregroundStyle(selected ? Slate.Text.primary : Slate.Text.icon)
            .padding(.horizontal, selected ? 8 : 6)
            .frame(height: Slate.Metric.plate)
            .background(
                selected ? Slate.State.hover : .clear,
                in: .rect(cornerRadius: Slate.Metric.radiusControl),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
