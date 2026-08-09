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
    /// The state this button's verb LANDS on, when the glyph should acknowledge the click by morphing
    /// rather than by anything moving. Every change of the value plays one short symbol bounce, so a
    /// chord or a menu row driving the same flag reads exactly like a click on the plate. `nil` (the
    /// default) leaves the glyph still — the plate's press fill is then the whole acknowledgement.
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
                // The press MORPH — see ``morphOn``. `.down` because a key that acknowledges a click
                // goes IN first; a value that never changes (the `nil` default, mapped to a constant)
                // never fires it.
                .symbolEffect(.bounce.down, options: .speed(1.4), value: morphOn ?? false)
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
    /// The morph namespace shared by ONE strip of tabs — see ``SlateCompactIsland/morph``. `nil`
    /// keeps the plain fade for any caller mounting a lone plate.
    var morph: Namespace.ID?
    var action: () -> Void = {}

    @State private var hovering = false

    init(
        mark: Mark, label: String, selected: Bool, showsLabel: Bool = true,
        morph: Namespace.ID? = nil, action: @escaping () -> Void = {},
    ) {
        self.mark = mark
        self.label = label
        self.selected = selected
        self.showsLabel = showsLabel
        self.morph = morph
        self.action = action
    }

    init(
        symbol: SFSymbol, label: String, selected: Bool, showsLabel: Bool = true,
        morph: Namespace.ID? = nil, action: @escaping () -> Void = {},
    ) {
        self.init(
            mark: .symbol(symbol), label: label, selected: selected, showsLabel: showsLabel,
            morph: morph, action: action,
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
    @ViewBuilder
    private var glyph: some View {
        switch mark {
        case let .symbol(symbol):
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
        case .android:
            AndroidRobotMark(side: Slate.Metric.androidMark)
        }
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
