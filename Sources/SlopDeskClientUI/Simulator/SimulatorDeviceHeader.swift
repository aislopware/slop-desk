// SimulatorDeviceHeader — what device this is, and what is true about it right now.
//
// The panel used to open straight onto a rectangle: correct, and impossible to caption. Someone with
// two 17 Pros on two runtimes could not tell which one they were driving, the resolution was
// unknowable without a screenshot and a ruler, and a pinned GPS position was invisible the moment
// the popover closed. Every line here answers one of those.
//
// EVERY FIGURE IS MEASURED, none is assumed. The resolution comes from the decoder's own format
// description, the runtime and the name from the device list, the position from the call that
// actually succeeded. The one number the reference designs show that is NOT here is uptime: the
// server's device entry carries `name`, `runtime`, `state` and `udid` and nothing else, so a
// "booted 3m ago" would be this panel timing its own first sighting and calling it the device's age.
// It would read as fact and be wrong after every client restart.
//
// IT IS A TITLE, not another row. The first cut set the device name at the same 12pt every list row
// uses and its facts at 10 — two greys a point apart, so the band read as a row that happened to
// wrap rather than as the caption for everything below it. The name now takes the `title` rung, the
// one size in the system whose job is to outrank the content it names, and the facts sit under it on
// the name's own left rail. Nothing else in the panel is allowed that size, which is what makes it
// mean "this is the subject".
//
// THE BACK CONTROL LIVES HERE rather than in the toolbar. The toolbar is verbs that act on the
// device; leaving the device is navigation, and putting it beside the device's own name is where
// every split view in the app already puts it.
//
// NO COLOURED STATUS INDICATOR, here or anywhere else in the panel (user-directed 2026-08-04). See
// `state` below for the argument; the rule it leaves behind is worth stating once for the whole
// panel, because three surfaces used to break it independently: a hue means SOMETHING IS WRONG, and
// nothing else. Healthy states ride luminance and weight — which is the same conclusion the 07-30
// round reached when it reversed hue as a status channel across the workspace.

#if os(macOS)
import SFSafeSymbols
import SwiftUI

struct SimulatorDeviceHeader: View {
    var device: SimulatorDevice
    var resolution: CGSize?
    var orientation: SimulatorOrientation
    var pinnedLocation: SimulatorCoordinate?
    var isStreaming: Bool
    var onBack: () -> Void

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            PlateIconButton(symbol: .chevronLeft) { onBack() }
                .help("All Devices")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Slate.Metric.space2) {
                    Text(device.name)
                        .font(.system(size: Slate.Typeface.title, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    state
                }
                SlateFactLine(facts: facts)
            }
        }
        .animation(Slate.Anim.smallFade, value: isStreaming)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
        .background(Slate.Surface.ground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Slate.Line.divider)
                .frame(height: Slate.Metric.hairline)
        }
    }

    /// ONLY THE ABNORMAL STATE, and without hue (user-directed 2026-08-04). The first cut lit a green
    /// dot captioned "Live" whenever frames were arriving, which is the ornament this app has already
    /// removed twice: `ConnectionStatusPill` was deleted for it, and the 07-30 round reversed hue as a
    /// state channel outright. A live mirror is its own evidence — the picture six points below this
    /// line is moving, and a badge asserting that it is moving adds no fact while spending the eye's
    /// one colour budget on the ordinary case. What DOES deserve a caption is the moment the picture
    /// is not there yet, because a stalled rectangle and a black screenshot look identical. So the
    /// slot is empty while streaming and carries a plain grey word while it is not, in the same
    /// instrument voice the facts below it use.
    @ViewBuilder private var state: some View {
        if !isStreaming {
            Text("Connecting…")
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .regular))
                .foregroundStyle(Slate.Text.tertiary)
                .fixedSize()
                .transition(.opacity)
        }
    }

    /// Ordered by how often it is the thing being checked. The runtime first — the usual reason two
    /// rows look identical — then the pixel size, then the short UDID, which is what every other
    /// tool wants pasted into it. Orientation and position appear only when they have something to
    /// say: a portrait device and a device using live GPS are the ordinary case, and printing them
    /// would spend the line's width on the absence of news.
    private var facts: [SlateFact] {
        var facts = [SlateFact("Runtime", device.runtime, tint: Slate.Text.secondary)]
        if let resolution {
            facts.append(SlateFact(
                "Resolution", Self.pixels(resolution),
                tint: Slate.Text.tertiary, isMeasured: true,
            ))
        }
        if orientation != .portrait {
            facts.append(SlateFact(
                "Orientation", Self.title(for: orientation), copies: orientation.wireValue,
                tint: Slate.Text.tertiary,
            ))
        }
        if let pinnedLocation {
            // NOT accented. It appears only when a position is pinned, so its presence already says
            // the device is lying about where it is, and the toolbar plate that pinned it is latched
            // in the accent six points below — two accents for one state inside one band is the
            // colour noise this header just lost its status dot over.
            facts.append(SlateFact(
                "Simulated Location", pinnedLocation.readout,
                tint: Slate.Text.secondary, isMeasured: true,
            ))
        }
        // The UDID last and SHORT: the full value is 36 characters and would own the line, but the
        // leading block is enough to tell two devices apart, and Copy hands over the whole thing.
        facts.append(SlateFact(
            "UDID", Self.shortened(device.udid), copies: device.udid,
            tint: Slate.Text.tertiary, isMeasured: true,
        ))
        return facts
    }

    /// `1206 × 2622`. The MULTIPLICATION SIGN, not a lowercase x — this sits in a row of measured
    /// figures and a letter standing in for an operator is the detail that makes a panel look
    /// improvised.
    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// The leading block of a UDID, which is what a person reads to tell two devices apart.
    static func shortened(_ udid: String) -> String {
        String(udid.prefix(8))
    }

    static func title(for orientation: SimulatorOrientation) -> String {
        switch orientation {
        case .portrait: "Portrait"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        case .portraitUpsideDown: "Upside Down"
        }
    }
}
#endif
