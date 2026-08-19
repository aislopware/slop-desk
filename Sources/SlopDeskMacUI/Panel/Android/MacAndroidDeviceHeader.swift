// MacAndroidDeviceHeader — what device this is, and what is true about it right now, in AppKit
// (docs/56 stage D, increment 52b).
//
// The Mac's half of ``AndroidDeviceHeader``. WHICH facts a device has, in what order, and which of
// them was read off a machine is ``AndroidPresentation/facts(for:)``; this turns that list into a
// ``MacAndroidFactLine`` and nothing else.
//
// The band above the stage: the way back, the device's name, the facts about it, and the verbs that
// act on it. Structurally identical to ``MacSimulatorDeviceHeader``, and every rule that header
// records applies here unchanged — the title outranks the content it names, the back control lives
// beside the name rather than in the toolbar, no coloured status indicator, no connecting caption.
//
// WHAT DIFFERS IS THAT THE FACTS ARE ACTUALLY KNOWN. `docs/47` explains that a simulator's header can
// print a resolution only once the decoder has told it one, because the server knows four things about
// a device and geometry is not among them. Android reports its screen size, its density and its API
// level for a device that has never booted, so this line is real from the moment the list arrives —
// and the STREAM's size is deliberately not printed beside them. The panel mirrors at a cap
// (``AndroidSidebarModel/streamMaxSize``), so the encoded size is a fact about this panel's request
// and not about the device; printing both would be two resolutions in one line, one of them wrong for
// every purpose anyone would use it for.

import AppKit
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacAndroidDeviceHeader: NSView {
    /// - Parameter actions: the verbs that act on this device, right-aligned in the same band. The
    ///   header takes the assembled view rather than building it, because which verbs a stage offers
    ///   is the stage's question and this band is also drawn without any.
    init(device: AndroidDevice, actions: NSView?, onBack: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        let back = MacPlateIconButton(symbolName: SFSymbol.chevronLeft.rawValue)
        back.toolTip = AndroidPresentation.backHelp
        back.setAccessibilityLabel(AndroidPresentation.backHelp)
        back.onClick = onBack

        let title = NSStackView(views: [
            macDevicePanelLabel(
                device.name, size: Slate.Typeface.title, weight: .semibold,
                color: MacAndroidInk.color(.primary),
            ),
        ])
        title.orientation = .horizontal
        title.alignment = .firstBaseline
        title.spacing = Slate.Metric.space1
        // The platform version rides the TITLE, not the facts line, for the reason the simulator
        // header gives its runtime: it is half of what NAMES a device. Two Pixel 7 AVDs differ by
        // nothing else, and on the facts line it would be one dot-separated figure among four.
        if let version = device.versionLabel {
            let label = macDevicePanelLabel(
                version, size: Slate.Typeface.footnote, color: MacAndroidInk.color(.tertiary),
            )
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            title.addArrangedSubview(label)
        }
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        title.addArrangedSubview(titleSpacer)

        let identity = NSStackView(views: [
            title, MacAndroidFactLine(AndroidPresentation.facts(for: device)),
        ])
        identity.orientation = .vertical
        identity.alignment = .leading
        // Two points, not a spacing rung: the facts are a CAPTION under the name rather than a second
        // line of the band, and at `space1` they read as their own row.
        identity.spacing = 2
        // The identity yields its width first: the verbs are fixed-size plates and the name
        // truncates, which is the right way round — a clipped rail would put a verb somewhere the
        // pointer cannot reach, while a clipped name is still a name.
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let band = NSStackView(views: [back, identity])
        band.orientation = .horizontal
        band.alignment = .centerY
        band.spacing = Slate.Metric.space2
        band.translatesAutoresizingMaskIntoConstraints = false
        if let actions { band.addArrangedSubview(actions) }

        addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            band.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            band.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            band.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // No rule under it and no tone change: header and stage share the ground (ONE ISLAND, law 1), so
    // this reads as a caption over the device rather than a bar above it. See ``MacSimulatorBezelView``
    // for the retired MERIDIAN L5 two-surface split it used to carry.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }
}
