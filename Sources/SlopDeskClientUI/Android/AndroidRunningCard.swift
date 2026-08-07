// AndroidRunningCard — an attached device in the list, drawn at its own proportions.
//
// A CARD AND NOT A ROW, for the reason its simulator twin gives: an attached device is the thing you
// are most likely to want, and the shape of its screen is worth the width.
//
// BUT NOT A LIVE THUMBNAIL, which is where the two panels part. The measurement is in
// ``AndroidDeviceList``'s header: `adb exec-out screencap -p` is 300 KB in ~250 ms with no scale or
// quality parameter to soften it, against 13.5 KB in 22 ms for the simulator server's scaled JPEG. A
// two-second poll per listed device would be 150 KB/s and a real slice of a phone's CPU, to fill a
// box a fifth of a panel wide.
//
// WHAT THE BOX HOLDS INSTEAD is the device's true PROPORTIONS. Android reports its screen size
// exactly, booted or not, so the rectangle drawn here is the rectangle the device is — a phone comes
// out 92 wide at this height and a tablet 150, side by side and unmistakable, which is most of what
// the picture was carrying. It is the same claim the simulator card makes and the same one it
// declines to make: the SHAPE, which is known, and not the SIZE, which is not (nothing here knows a
// device's physical inches, and density is a rendering bucket rather than a ruler).
//
// A DEVICE THAT IS ATTACHED BUT NOT USABLE gets the same card with its state said out loud. That is
// the case worth designing for: `unauthorized` means a dialog is waiting on the device's own screen,
// and it is the one condition where the panel can do nothing at all and the user can fix it in two
// seconds — provided they are told.

#if os(macOS)
import AppKit
import SFSafeSymbols
import SwiftUI

struct AndroidRunningCard: View {
    let model: AndroidSidebarModel
    let device: AndroidDevice
    let onOpen: () -> Void

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
        // A booting emulator opens too: the stage knows how to wait for a device now, and "click,
        // then watch it come up" is strictly better than "watch the list until clicking works".
        // A physical device that is attached-but-unusable stays un-clickable — its fix (an
        // authorization dialog on its own screen) is not something waiting can do.
        .onTapGesture { if device.isRunning || device.isEmulator && device.serial != nil { onOpen() } }
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .help(help)
    }

    private var help: String {
        device.isRunning ? "Open \(device.name)" : "\(device.name) — \(Self.explain(device))"
    }

    /// The screen box: a FIXED height and a width that follows the device's own aspect, so what varies
    /// between two cards is the shape and nothing else.
    ///
    /// The family glyph sits inside it rather than a picture. Large — this is the one place in the
    /// panel where a silhouette has room to be read rather than to be a bullet — and in the icon ink,
    /// so the rectangle's proportions stay the loudest thing about the box.
    private var art: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .fill(Slate.Surface.ground)
            if device.isAttachedButUnusable {
                // The one state that gets a word instead of a glyph. `unauthorized` is fixed by
                // looking at the device, and a symbol cannot say that.
                Text(Self.explain(device))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(Slate.Metric.space1)
            } else {
                Image(systemSymbol: AndroidDeviceKind.infer(device).symbol)
                    .font(.system(size: Slate.Typeface.display, weight: .light))
                    .foregroundStyle(Slate.Text.icon)
            }
        }
        .frame(width: boxWidth, height: Slate.Metric.deviceCardArt)
        .frame(maxWidth: .infinity)
    }

    /// The box's width at the card's fixed art height, from the device's own aspect ratio. Clamped so
    /// an unreported or absurd ratio cannot produce a box wider than the card — the fallback is a
    /// portrait phone's proportions, which is the shape most likely to be right.
    private var boxWidth: CGFloat {
        let ratio = device.aspectRatio ?? Self.fallbackAspect
        let width = Slate.Metric.deviceCardArt * ratio
        return min(max(width, Slate.Metric.heightBar), Slate.Metric.deviceCardWidth)
    }

    /// 9:19.5 — the proportions of essentially every current Android phone, and the right guess for a
    /// device that has not said.
    static let fallbackAspect: CGFloat = 9.0 / 19.5

    private var caption: some View {
        HStack(spacing: Slate.Metric.space1) {
            AndroidFamilyMark(device: device)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !device.summary.isEmpty {
                    Text(device.summary)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            control
        }
    }

    /// Stop, and only for an emulator. A physical device is somebody's phone: this panel mirrors it
    /// and does not power it off, so the plate is simply absent rather than present-and-refusing.
    @ViewBuilder
    private var control: some View {
        if model.pending.contains(device.key) {
            WorkingSpinner()
                .frame(width: Slate.Metric.heightControl, height: Slate.Metric.heightControl)
        } else if device.isEmulator, device.isRunning {
            SlatePlateButton(
                symbol: .stopFill,
                help: "Shut down \(device.name)",
                size: Slate.Typeface.footnote,
                plate: Slate.Metric.heightControl,
                tint: hovering ? Slate.Text.primary : Slate.Text.tertiary,
            ) {
                Task { await model.shutdown(device) }
            }
        }
    }

    /// The device's state as a sentence, with the one reading `adb`'s word alone would get wrong:
    /// an EMULATOR that is `offline` is almost always a boot in progress — the serial registers
    /// within seconds of launch and the guest's `adbd` answers ~21 s later (measured 2026-08-07) —
    /// and "Not responding" over a card that is doing exactly what was asked reads as a fault.
    static func explain(_ device: AndroidDevice) -> String {
        if device.isEmulator, device.state == "offline" { return "Starting up…" }
        return explain(device.state)
    }

    /// `adb`'s state word as a sentence. The words are `adb`'s own and mean nothing to most readers —
    /// `unauthorized` in particular reads as a permissions error on the HOST, when what it means is
    /// that a dialog is waiting on the device's screen.
    static func explain(_ state: String) -> String {
        switch state {
        case "unauthorized": "Waiting for you to allow debugging on the device"
        case "offline": "Not responding"
        case "authorizing": "Authorizing…"
        case "connecting": "Connecting…"
        case "recovery": "In recovery mode"
        case "sideload": "In sideload mode"
        case "bootloader": "In the bootloader"
        case "device": "Ready"
        default: state
        }
    }
}
#endif
