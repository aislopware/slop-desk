// DeviceSurfaces — the two device surfaces' ONE remaining view job: the drill between a list and a
// device.
//
// What used to stand around them — the phase switch, the two poll loops, the park/resume pair, the
// reports — left with the rest of the panel in docs/56 increment 51. The phase is
// ``CodePanelPresentation``'s fold and the loops belong to whichever framework is mounting, so what is
// left here is the part that is genuinely a view and nothing else.
//
// THE LIST AND THE DEVICE ARE ONE SURFACE AT TWO DEPTHS, so the swap between them is a DRILL, not a
// cut. The stage always enters from the trailing side and leaves back that way, the list always from
// the leading side — one direction per view, which is what makes "in" and "out" legible without either
// of them knowing which way the last move went.
//
// The shift is a NUDGE, not a page slide. A full-width push of a live H.264 surface is 200ms of a
// video layer being composited across the panel to say something a few points of parallax already say;
// the depth cue is the offset's direction, and the fade carries the rest.
//
// A ZSTACK rather than a plain `if`/`else`: mid-transition both views are mounted, and inside a `VStack`
// the outgoing list would squeeze the arriving device for the length of the fade.
//
// PHONE-ONLY SINCE INCREMENT 52. The Mac drew the same two depths through this file for exactly one
// increment — the hosting seam narrowed to these two surfaces before it closed — and now has
// ``SlopDeskMacUI/MacSimulatorSurface`` and ``SlopDeskMacUI/MacAndroidSurface``, which say the same
// three things (drill, direction, both mounted mid-beat) in four constraints each. The prose above is
// the shared decision; only the spelling of it is here.

#if os(iOS)
import SlopDeskDevicePanels
import SlopDeskSlate
import SwiftUI

/// The Simulators surface's two depths.
struct SimulatorSurface: View {
    let model: SimulatorSidebarModel

    var body: some View {
        ZStack {
            if model.selection != nil {
                SimulatorStageView(model: model)
                    .transition(deviceDrill(from: Slate.Metric.space4))
            } else {
                SimulatorDeviceList(model: model)
                    .transition(deviceDrill(from: -Slate.Metric.space4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Android surface's two depths — the same drill, over a device set that shares not one byte of
/// protocol with the one above (`baguette`'s websocket against `scrcpy` over `adb`, AVC against
/// Annex-B, JSON envelopes against packed control messages). Two surfaces that happen to look alike.
struct AndroidSurface: View {
    let model: AndroidSidebarModel

    var body: some View {
        ZStack {
            if model.selection != nil {
                AndroidStageView(model: model)
                    .transition(deviceDrill(from: Slate.Metric.space4))
            } else {
                AndroidDeviceList(model: model)
                    .transition(deviceDrill(from: -Slate.Metric.space4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Enter from `shift`, leave back to it — symmetric, because a view's side of the hierarchy does not
/// change with the direction of travel.
private func deviceDrill(from shift: CGFloat) -> AnyTransition {
    .offset(x: shift).combined(with: .opacity)
}
#endif
