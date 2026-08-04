// SimulatorRunningCard — a running device in the list, drawn as its own screen.
//
// WHY A CARD AND NOT A ROW. The panel is ~700pt wide and, for a device that is OFF, the server knows
// exactly four things about it: name, runtime, state, udid. Three are already on screen and the
// fourth is in the context menu, so there is no fifth fact to widen a row with — measured 2026-08-04,
// `definition.json` cannot supply one either, because it is CHROME data that falls back to a near
// model (iPhone Air comes back as the 17 Pro Max body; iPad Pro 11-inch, both iPad Airs and iPad
// (A16) all come back the same size). A size column built on it would be wrong for four of eleven
// devices, and a per-row silhouette would draw three of them as each other.
//
// A device that is RUNNING has a fact none of the others do: a screen. That is what fills the panel
// here, and it is why only the running group is drawn this way — the card is not a decorated row, it
// is the one place there is something to look at.
//
// THE PICTURE IS AFFORDABLE BECAUSE IT IS SMALL. `screenshot.jpg` at native resolution is 480 KB;
// the same capture at the server's `scale=6&quality=0.5` is 13.5 KB in 22 ms (both measured
// 2026-08-04 — see `SimulatorEndpoints.screenshot`). At the two-second cadence that is 6.8 KB/s per
// running device, a fifth of what an idle VIDEO stream costs, where a native-resolution poll would
// have been seven times more than the stream.
//
// The poll rides `.task`, so it dies with the view — deliberately unlike the model's sockets, which
// outlive their view and needed an explicit `park()` (see ``SimulatorSidebarModel/park()``). A card
// exists only while the list is on screen, so the view's own lifetime is exactly the right one.

#if os(macOS)
import AppKit
import SFSafeSymbols
import SwiftUI

struct SimulatorRunningCard: View {
    let model: SimulatorSidebarModel
    let device: SimulatorDevice
    let onOpen: () -> Void

    /// The last picture that arrived. Kept across a failed poll rather than blanked: the server
    /// answers 500 for a device that has just gone away, and a card that flickered to grey for one
    /// round would be reporting a stumble the reader cannot act on.
    @State private var screen: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            art
            caption
        }
        .padding(Slate.Metric.space2)
        .background(
            hovering ? Slate.State.selected : Slate.Surface.raised,
            in: .rect(cornerRadius: Slate.Metric.radiusCard),
        )
        .overlay {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .strokeBorder(Slate.Line.card, lineWidth: Slate.Metric.cardBorderWidth)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .help("Open \(device.name)")
        .task(id: device.udid) { await poll() }
    }

    /// The screen box. A FIXED height and a free width, so what varies between two cards is the ASPECT
    /// and nothing else: a phone comes out 92 wide and an iPad 132, side by side and unmistakable.
    ///
    /// Not to true relative SIZE, and not by choice — an iPad mini really is the bigger object, but
    /// nothing here knows by how much. The capture's pixel dimensions are real, and useless for this:
    /// the phone reports 1206 × 2622 at 3× and the iPad 1488 × 2266 at 2×, and the scale factor is not
    /// in anything the server sends. `definition.json` has a point size and it is the chrome fallback
    /// number, wrong for four of this host's eleven devices. A normalised box is what is left, and it
    /// is the honest one: it claims the shape, which is known, and not the size, which is not.
    private var art: some View {
        ZStack {
            if let screen {
                Image(nsImage: screen)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The framebuffer is a rectangle; every device that can run this is not. Clipping
                    // to the card's own radius is the smallest true thing to say about the body —
                    // the server's real `clipRadius` is part of the chrome data that falls back to
                    // the wrong model, so it is not worth being precise with.
                    .clipShape(.rect(cornerRadius: Slate.Metric.radiusCard))
                    .transition(.opacity)
            } else {
                // What a card shows for the second between a boot landing in the device list and the
                // first capture coming back — and ONLY then. A plate left permanently behind the
                // picture letterboxes it: a phone is 92 of the box's 164 points, so the two points of
                // grey either side of the screen read as a second rectangle rather than as the card's
                // own padding. No spinner: the capture is 22 ms, so an indicator would be a flash, and
                // this panel has already been bitten once by an indicator drawn from "nothing has
                // arrived yet" (see `docs/47`).
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .fill(Slate.Surface.ground)
            }
        }
        .frame(height: Slate.Metric.deviceCardArt)
        .frame(maxWidth: .infinity)
        // The FIRST picture fades in; the ones after it replace in place. Cross-fading every frame
        // would smear a scroll or a keyboard appearing into a dissolve, which reads as a slow panel
        // rather than as a live one.
        .animation(Slate.Anim.fadeSlideIn, value: screen == nil)
    }

    private var caption: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(device.name)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.pending.contains(device.udid) {
                WorkingSpinner()
                    .frame(width: Slate.Metric.heightControl, height: Slate.Metric.heightControl)
            } else {
                SlatePlateButton(
                    symbol: .stopFill,
                    help: "Shut down \(device.name)",
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: hovering ? Slate.Text.primary : Slate.Text.tertiary,
                ) {
                    Task { await model.shutdown(device.udid) }
                }
            }
        }
    }

    /// Ask for a picture, wait, ask again — for as long as this card is on screen. Cancellation is
    /// the view going away, which is the tab changing, the panel collapsing, the device shutting
    /// down, or a click opening the stage.
    private func poll() async {
        while !Task.isCancelled {
            if let data = await model.thumbnail(for: device.udid),
               let image = NSImage(data: data)
            {
                screen = image
            }
            try? await Task.sleep(for: SimulatorSidebarModel.thumbnailCadence)
        }
    }
}
#endif
