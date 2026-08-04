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
// THE BACK CONTROL LIVES HERE rather than in the toolbar. The toolbar is verbs that act on the
// device; leaving the device is navigation, and putting it beside the device's own name is where
// every split view in the app already puts it.

#if os(macOS)
import AppKit
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
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            HStack(spacing: Slate.Metric.space1) {
                PlateIconButton(symbol: .chevronLeft) { onBack() }
                    .help("All Devices")
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base, weight: .semibold))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Slate.Metric.space1)
                status
            }
            facts
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
        .background(Slate.Surface.ground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Slate.Line.divider)
                .frame(height: Slate.Metric.hairline)
        }
    }

    /// A dot and a word, not a spinner. The question is whether pixels are arriving, which is a
    /// STATE — a spinner claims progress toward something finishing, and a live mirror never
    /// finishes.
    private var status: some View {
        HStack(spacing: Slate.Metric.space1) {
            Circle()
                .fill(isStreaming ? Slate.Status.ok : Slate.Text.tertiary)
                .frame(width: Slate.Metric.dot, height: Slate.Metric.dot)
            Text(isStreaming ? "Live" : "Connecting")
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.tertiary)
        }
        .animation(Slate.Anim.smallFade, value: isStreaming)
    }

    /// The facts line. Wrapping rather than truncating: at a sidebar's width the runtime and the
    /// resolution do not both fit beside a long device name, and eliding the one that happens to be
    /// last is how a panel ends up never showing the resolution on exactly the models with long
    /// names.
    private var facts: some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { separator }
                fact(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Slate.Metric.plate + Slate.Metric.space1)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: Slate.Typeface.small))
            .foregroundStyle(Slate.Text.tertiary)
    }

    private func fact(_ item: Item) -> some View {
        Text(item.text)
            .font(item.isMono
                ? Slate.Typeface.instrument(Slate.Typeface.small, weight: .regular)
                : .system(size: Slate.Typeface.small))
            .foregroundStyle(item.tint)
            .lineLimit(1)
            .help(item.help)
            .contextMenu {
                Button("Copy \(item.help)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.copies, forType: .string)
                }
            }
    }

    private struct Item {
        var text: String
        var help: String
        var copies: String
        var tint: Color
        var isMono = false
    }

    /// Ordered by how often it is the thing being checked. The runtime first — the usual reason two
    /// rows look identical — then the pixel size, then the short UDID, which is what every other
    /// tool wants pasted into it.
    private var items: [Item] {
        var items: [Item] = [
            Item(
                text: device.runtime, help: "Runtime", copies: device.runtime,
                tint: Slate.Text.secondary,
            ),
        ]
        if let resolution {
            items.append(Item(
                text: Self.pixels(resolution), help: "Resolution",
                copies: Self.pixels(resolution), tint: Slate.Text.tertiary, isMono: true,
            ))
        }
        if orientation != .portrait {
            items.append(Item(
                text: Self.title(for: orientation), help: "Orientation",
                copies: orientation.wireValue, tint: Slate.Text.tertiary,
            ))
        }
        if let pinnedLocation {
            items.append(Item(
                text: pinnedLocation.readout, help: "Simulated Location",
                copies: pinnedLocation.readout, tint: Slate.State.accent, isMono: true,
            ))
        }
        // The UDID last and SHORT: the full value is 36 characters and would own the line, but the
        // leading block is enough to tell two devices apart, and Copy hands over the whole thing.
        items.append(Item(
            text: Self.shortened(device.udid), help: "UDID", copies: device.udid,
            tint: Slate.Text.tertiary, isMono: true,
        ))
        return items
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
