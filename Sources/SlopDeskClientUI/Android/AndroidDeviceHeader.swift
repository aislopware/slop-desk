// AndroidDeviceHeader — what device this is, and what is true about it right now.
//
// The band above the stage: the way back, the device's name, the facts about it, and the verbs that
// act on it. Structurally identical to ``SimulatorDeviceHeader``, and every rule that header records
// applies here unchanged — the title outranks the content it names, the back control lives beside the
// name rather than in the toolbar, no coloured status indicator, no connecting caption.
//
// WHAT DIFFERS IS THAT THE FACTS ARE ACTUALLY KNOWN. `docs/47` explains that a simulator's header can
// print a resolution only once the decoder has told it one, because the server knows four things about
// a device and geometry is not among them. Android reports its screen size, its density and its API
// level for a device that has never booted, so this line is real from the moment the list arrives —
// and the STREAM's size is deliberately not printed beside them. The panel mirrors at a cap
// (``AndroidSidebarModel/streamMaxSize``), so the encoded size is a fact about this panel's request
// and not about the device; printing both would be two resolutions in one line, one of them wrong for
// every purpose anyone would use it for.

#if os(macOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SwiftUI

struct AndroidDeviceHeader<Actions: View>: View {
    var device: AndroidDevice
    var onBack: () -> Void
    /// The verbs that act on this device, right-aligned in the same band. Declared last so a caller
    /// can pass them as a trailing closure — and AFTER `onBack` so an unlabelled one still binds to
    /// the view builder rather than to the navigation handler.
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            PlateIconButton(symbol: .chevronLeft) { onBack() }
                .help("All Devices")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space1) {
                    Text(device.name)
                        .font(.system(size: Slate.Typeface.title, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The platform version rides the TITLE, not the facts line, for the reason the
                    // simulator header gives its runtime: it is half of what NAMES a device. Two
                    // Pixel 7 AVDs differ by nothing else, and on the facts line it would be one
                    // dot-separated figure among four.
                    if let version = device.versionLabel {
                        Text(version)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.tertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
                SlateFactLine(facts: facts)
            }
            // The identity yields its width first: the verbs are fixed-size plates and the name
            // truncates, which is the right way round — a clipped rail would put a verb somewhere the
            // pointer cannot reach, while a clipped name is still a name.
            .layoutPriority(-1)
            actions()
        }
        // Keyed on WHICH facts are present, not on their values.
        .animation(Slate.Anim.smallFade, value: facts.map(\.id))
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
        // No rule under it and no tone change: header and stage share the ground (ONE ISLAND, law 1),
        // so this reads as a caption over the device. See ``SimulatorStageView`` for the retired
        // MERIDIAN L5 split it used to carry.
        .background(Slate.Surface.field)
    }

    /// Ordered by how often it is the thing being checked: the screen, then the SERIAL, which is what
    /// every other tool wants pasted into it (`adb -s`, a Gradle install target, a bug report).
    /// Density and ABI appear only where they are known.
    private var facts: [SlateFact] {
        var facts: [SlateFact] = []
        if let width = device.width, let height = device.height {
            facts.append(SlateFact(
                "Screen", "\(width) × \(height)",
                tint: Slate.Text.secondary, isMeasured: true,
            ))
        }
        if let density = device.density {
            // `420 dpi` rather than the bucket's name (`xxhdpi`): the number is what a layout is
            // reasoned about in, and the bucket is derivable from it while the reverse is not.
            facts.append(SlateFact(
                "Density", "\(density) dpi", tint: Slate.Text.tertiary, isMeasured: true,
            ))
        }
        if let abi = device.abi, !abi.isEmpty {
            // Unlabelled: `arm64-v8a` names itself, and it is here because a native build that
            // refuses to install is almost always this line disagreeing with the APK.
            facts.append(SlateFact(
                "ABI", abi, tint: Slate.Text.tertiary, showsLabel: false,
            ))
        }
        if let serial = device.serial {
            facts.append(SlateFact(
                "Serial", serial, copies: serial, tint: Slate.Text.tertiary, isMeasured: true,
            ))
        }
        return facts
    }
}
#endif
