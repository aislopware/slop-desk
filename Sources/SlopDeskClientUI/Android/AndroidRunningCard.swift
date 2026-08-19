// AndroidRunningCard — an attached device in the list, drawn at its own proportions, ON THE PHONE.
//
// iOS-ONLY SINCE docs/56 INCREMENT 52b; ``SlopDeskMacUI/MacAndroidRunningCard`` draws the same card in
// AppKit. What descended rather than being spelled twice: the aspect clamp
// (``AndroidPresentation/artWidth(for:art:floor:cap:)``), the tooltip, and the two `explain` folds —
// the last of which is the one this file most wanted to keep, and precisely the reason it could not:
// `adb`'s state words turned into English is a TABLE, and a table copied into a second framework grows
// a case on one side only.
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

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
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
        // WHETHER THE TAP OPENS ANYTHING is ``AndroidPresentation/canEnter(_:)`` — the same predicate
        // the list's own `enter(_:)` asks, which is the point: it used to be spelled here AND there,
        // one edit away from a card that opens a booting emulator and a row that refuses it.
        .onTapGesture { if AndroidPresentation.canEnter(device) { onOpen() } }
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .help(AndroidPresentation.cardHelp(device))
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
                .fill(Slate.Surface.raised)
            if device.isAttachedButUnusable {
                // The one state that gets a word instead of a glyph. `unauthorized` is fixed by
                // looking at the device, and a symbol cannot say that.
                Text(AndroidPresentation.explain(device))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(AndroidInk.tertiary.color)
                    .multilineTextAlignment(.center)
                    .padding(Slate.Metric.space1)
            } else {
                Image(systemSymbol: AndroidDeviceKind.infer(device).symbol)
                    .font(.system(size: Slate.Typeface.display, weight: .light))
                    .foregroundStyle(AndroidInk.icon.color)
            }
        }
        .frame(width: boxWidth, height: Slate.Metric.deviceCardArt)
        .frame(maxWidth: .infinity)
    }

    /// The box's width at the card's fixed art height, from the device's own aspect ratio, clamped so
    /// an unreported or absurd ratio cannot produce a box wider than the card.
    ///
    /// The three LENGTHS are this half's, because they are design tokens and Slate sits above the
    /// target the arithmetic lives in; the fallback and the order of the clamp are shared, because
    /// those are the parts that would drift.
    private var boxWidth: CGFloat {
        AndroidPresentation.artWidth(
            for: device,
            art: Slate.Metric.deviceCardArt,
            floor: Slate.Metric.heightBar,
            cap: Slate.Metric.deviceCardWidth,
        )
    }

    private var caption: some View {
        HStack(spacing: Slate.Metric.space1) {
            AndroidFamilyMark(device: device)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base, weight: .medium))
                    .foregroundStyle(AndroidInk.primary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !device.summary.isEmpty {
                    Text(device.summary)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(AndroidInk.tertiary.color)
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
                help: AndroidPresentation.shutDownHelp(device),
                size: Slate.Typeface.footnote,
                plate: Slate.Metric.heightControl,
                tint: hovering ? AndroidInk.primary.color : AndroidInk.tertiary.color,
            ) {
                Task { await model.shutdown(device) }
            }
        }
    }
}
#endif
