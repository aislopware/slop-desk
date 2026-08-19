// MacSimulatorDeviceHeader — what device this is, and what is true about it right now, in AppKit
// (docs/56 stage D, increment 52a).
//
// The panel used to open straight onto a rectangle: correct, and impossible to caption. Someone with
// two 17 Pros on two runtimes could not tell which one they were driving, the resolution was
// unknowable without a screenshot and a ruler, and a pinned GPS position was invisible the moment the
// popover closed. Every line here answers one of those.
//
// EVERY FIGURE IS MEASURED, none is assumed. The resolution comes from the decoder's own format
// description, the runtime and the name from the device list, the position from the call that actually
// succeeded. WHICH facts appear, in what order and under which label is
// ``SimulatorPresentation/facts(device:resolution:orientation:pinnedLocation:)`` — the phone's header
// reads the same list, and neither re-decides. The one number the reference designs show that is NOT
// there is uptime: the server's device entry carries `name`, `runtime`, `state` and `udid` and nothing
// else, so a "booted 3m ago" would be this panel timing its own first sighting and calling it the
// device's age.
//
// IT IS A TITLE, not another row. The first cut set the device name at the same 12pt every list row
// uses and its facts at 10 — two greys a point apart, so the band read as a row that happened to wrap
// rather than as the caption for everything below it. The name takes the `title` rung, the one size in
// the system whose job is to outrank the content it names, and nothing else in the panel is allowed
// that size.
//
// THE BACK CONTROL LIVES HERE rather than in the toolbar: the toolbar is verbs that act on the device,
// leaving the device is navigation, and putting it beside the device's own name is where every split
// view in the app already puts it. AND SO DO THE VERBS (user-directed 2026-08-04) — this band's
// trailing half was empty at every panel size, and the same ten plates that read as "beside the
// device" in a narrow column read as specks scattered along the floor of a wide one.
//
// NO COLOURED STATUS INDICATOR, and no "Connecting…" caption either (both user-directed 2026-08-04).
// The first was a hue carrying a healthy state, which this app has reversed twice; the second
// captioned the state from OUTSIDE the thing it was about and had no end. The ambiguous object is the
// empty rectangle below, so the word belongs on the rectangle — ``MacSimulatorStageView`` puts a
// proper, ending indicator there. This band is facts.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSimulatorDeviceHeader: NSView {
    /// - Parameter actions: the verbs that act on this device, right-aligned in the same band. Built by
    ///   the stage, because they are the stage's model calls; the band only knows where they sit.
    init(
        device: SimulatorDevice,
        resolution: CGSize?,
        orientation: SimulatorOrientation,
        pinnedLocation: SimulatorCoordinate?,
        actions: NSView,
        onBack: @escaping () -> Void,
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // NO RULE UNDER IT and no tone change either (user-directed 2026-08-04): the header and the
        // stage are the SAME ground (ONE ISLAND — the panel sinks), so this line simply sits in the
        // field above the device, which is what a caption does. The hairline that used to be here
        // landed a few points under the tab strip's, and that is what made the top of the panel read
        // as a stack of bands rather than as a caption over a device.
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        let back = MacPlateIconButton(symbolName: "chevron.left")
        back.toolTip = SimulatorPresentation.backHelp
        back.onClick = onBack

        let name = macDevicePanelLabel(
            device.name, size: Slate.Typeface.title, weight: .semibold,
            color: Slate.Native.Text.primary,
        )
        // The runtime rides the TITLE, not the facts line: it is half of what names a device — two
        // iPhone 17 Pros differ by nothing else — and a caption reading "iPhone 17 Pro · iOS 26.5" is
        // how every simulator UI writes it. On the facts line it was one dot-separated figure among
        // four, which is where the thing you are actually looking for goes to hide.
        let runtime = macDevicePanelLabel(
            device.runtime, size: Slate.Typeface.footnote, color: Slate.Native.Text.tertiary,
        )
        runtime.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [name, runtime, NSView()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Slate.Metric.space1

        let facts = MacSimulatorFactLine(SimulatorPresentation.facts(
            device: device, resolution: resolution, orientation: orientation,
            pinnedLocation: pinnedLocation,
        ))

        let identity = NSStackView(views: [titleRow, facts])
        identity.orientation = .vertical
        identity.alignment = .leading
        // Two points, not a ladder rung: the facts are the name's own caption and sit on its baseline
        // rhythm rather than a step below it.
        identity.spacing = 2
        // The identity yields its width FIRST: the verbs are fixed-size plates and the name truncates,
        // which is the right way round — a clipped rail would put a verb somewhere the pointer cannot
        // reach, while a clipped name is still a name.
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identity.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [back, identity, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            titleRow.widthAnchor.constraint(equalTo: identity.widthAnchor),
            facts.widthAnchor.constraint(equalTo: identity.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }
}
