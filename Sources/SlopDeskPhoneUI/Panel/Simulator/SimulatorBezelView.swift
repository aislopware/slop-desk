// SimulatorBezelView — the live screen seated in the device's own body.
//
// Before this the stream was a rectangle on grey. A phone is not a rectangle: it has a body, the body
// has side buttons, and the screen's corners are rounded by the body that clips them. All three come
// from the server (``SimulatorChrome``), so drawing the real thing is a layout away — and inventing
// the proportions locally would be wrong per model and wrong again next year.
//
// LAYOUT. Everything is a fraction of the bezel's own viewport, scaled once by `fit`. The scale comes
// from the BLEED rect, not the viewport: side buttons protrude past the body, and fitting the
// viewport alone would clip them off at the panel's edge.
//
// Z-ORDER is the server's, and it is the whole trick — buttons draw UNDER the body. The body's own
// edge is what makes a protruding button look seated in the case rather than pasted beside it.
//
// PRESSES are press-and-hold, not clicks: `DragGesture(minimumDistance: 0)` so the artwork swaps on
// touch-down. The envelope goes on RELEASE, matching the hardware — a volume key that fired on the
// way down would repeat on every accidental brush of the trackpad.
//
// iOS-ONLY since docs/56 increment 52a; the Mac draws the same body in `MacSimulatorBezelView`. The
// three things a second renderer could get wrong — the turned footprint, the fit, and a button's name —
// are ``SimulatorPresentation``'s and are read from there by BOTH halves. They are geometry and words,
// not tokens, which is why they were allowed to descend at all.

#if os(iOS)
import SlopDeskDevicePanels
import SlopDeskSlate
import SwiftUI

struct SimulatorBezelView: View {
    var assets: SimulatorChromeAssets
    var frames: SimulatorFrameSink
    var orientation: SimulatorOrientation
    var send: (SimulatorInputEnvelope) -> Void
    /// Declared AFTER `send` so an unlabelled trailing closure still matches `send` — Swift's forward
    /// scan takes the first function-typed parameter it has not filled, and putting this one earlier
    /// would silently rebind every existing call site's gesture handler to the size callback.
    var onContentSize: ((CGSize) -> Void)?

    @State private var pressed: String?

    var body: some View {
        GeometryReader { proxy in
            let bleed = assets.chrome.bleed
            let scale = SimulatorPresentation.fit(
                bleed.size,
                in: SimulatorPresentation.footprint(proxy.size, turned: orientation.isLandscape),
            )
            let viewport = assets.chrome.screen.viewport
            ZStack(alignment: .topLeading) {
                ForEach(assets.chrome.buttons) { button in
                    self.button(button, viewport: viewport, scale: scale, origin: bleed.origin)
                }
                assets.body
                    .resizable()
                    .frame(width: viewport.width * scale, height: viewport.height * scale)
                    .offset(x: -bleed.minX * scale, y: -bleed.minY * scale)
                    .allowsHitTesting(false)
                screen(scale: scale, origin: bleed.origin)
            }
            .frame(width: bleed.width * scale, height: bleed.height * scale)
            // The WHOLE device turns — body, buttons and screen together. The framebuffer stays
            // portrait whatever the device is doing (see `SimulatorOrientation.viewAngle`), so this is
            // the only thing that has to change, and the screen view's own coordinate space is left
            // untouched: SwiftUI hit-tests a rotated view in its UNROTATED local space, which is
            // exactly the space the server expects a tap in.
            .rotationEffect(.degrees(orientation.viewAngle))
            .animation(Slate.Anim.smallFade, value: orientation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The live pixels, clipped to the body's own corner radius. Clipped rather than merely placed:
    /// unclipped video overhangs the rounded corners and reads as a rendering bug, which is exactly
    /// the "looks unfinished" the bezel is here to fix.
    private func screen(scale: CGFloat, origin: CGPoint) -> some View {
        let rect = assets.chrome.screen.rect
        return SimulatorScreenView(
            frames: frames, orientation: orientation, send: send, onContentSize: onContentSize,
        )
        .frame(width: rect.width * scale, height: rect.height * scale)
        .clipShape(.rect(cornerRadius: assets.chrome.screen.clipRadius * scale))
        .offset(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale)
    }

    private func button(
        _ button: SimulatorChrome.Button, viewport: CGSize, scale: CGFloat, origin: CGPoint,
    ) -> some View {
        let box = button.frame(in: viewport)
        let isDown = pressed == button.id
        let art = assets.buttons[button.id]
        return Group {
            if let art {
                (isDown ? art.pressed : art.rest)
                    .resizable()
            } else {
                // No artwork for this one: stay clickable but draw nothing. A coloured placeholder
                // would be a fake button on a photoreal body.
                Color.clear
            }
        }
        .frame(width: box.width * scale, height: box.height * scale)
        .contentShape(.rect)
        .offset(x: (box.minX - origin.x) * scale, y: (box.minY - origin.y) * scale)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = button.id }
                .onEnded { _ in
                    pressed = nil
                    send(.button(button.envelopeButton))
                },
        )
        .help(SimulatorPresentation.buttonLabel(for: button.id))
    }
}

/// The stream with no body around it — still loading, or a model the server cannot describe. Turned
/// the same way the bezel is, for the same reason: the framebuffer never rotates, so a landscape
/// device would otherwise read sideways here too.
struct SimulatorBareScreen: View {
    var frames: SimulatorFrameSink
    var orientation: SimulatorOrientation
    var send: (SimulatorInputEnvelope) -> Void
    /// After `send`, for the reason ``SimulatorBezelView`` states.
    var onContentSize: ((CGSize) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let box = SimulatorPresentation.footprint(proxy.size, turned: orientation.isLandscape)
            SimulatorScreenView(
                frames: frames, orientation: orientation, send: send, onContentSize: onContentSize,
            )
            .frame(width: box.width, height: box.height)
            .rotationEffect(.degrees(orientation.viewAngle))
            .animation(Slate.Anim.smallFade, value: orientation)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
#endif
