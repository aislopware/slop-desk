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
// AND SO DO THE VERBS, now (user-directed 2026-08-04). They used to float along the BOTTOM of the
// stage — the reasoning was that a device's controls belong beside the device rather than in a strip
// about it, and that giving them a band of their own would stripe the column dim/lit/dim/lit. Both
// held; what neither accounted for was the width. This band's trailing half was empty at every panel
// size, and the same ten plates that read as "beside the device" in a narrow column read as specks
// scattered along the floor of a wide one. Landing them here costs no new band — it fills the one
// that was already half empty — and puts the verbs where the eye enters the panel. The stage below is
// now nothing but the device.
//
// NO COLOURED STATUS INDICATOR, here or anywhere else in the panel (user-directed 2026-08-04). A
// green dot captioned "Live" used to sit at the end of the title line, which is the ornament this app
// has already removed twice: `ConnectionStatusPill` was deleted for it, and the 07-30 round reversed
// hue as a state channel outright. The rule it leaves behind is worth stating once for the whole
// panel, because three surfaces used to break it independently: a hue means SOMETHING IS WRONG, and
// nothing else. Healthy states ride luminance and weight.
//
// NO CONNECTING CAPTION EITHER (user-directed 2026-08-04). The dot's replacement was a grey
// "Connecting…" in the same slot, and it was wrong in two ways at once. It captioned the state from
// OUTSIDE the thing it was about — the ambiguous object is the empty rectangle below, so the word
// belongs on the rectangle, where `SimulatorStageView` now puts a proper indicator. And it had no
// end: it was drawn from "no frames yet", a condition that never expires, so a stream that would
// never start left the word up forever. Both are fixed at the source; this header is facts again.
//
// iOS-ONLY since docs/56 increment 52a; the Mac draws the same band in `MacSimulatorDeviceHeader`.
// WHICH facts are present and in what order is ``SimulatorPresentation/facts(device:resolution:orientation:pinnedLocation:)``'s
// — that was the half a second renderer would have re-derived from this file's prose and got subtly
// wrong, exactly as increment 51 recorded for the workbench. What stays here is the DRAWING, plus the
// four lines that turn a role into a hue, which cannot descend: `SlopDeskSlate` depends on the target
// the fold lives in.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import SwiftUI

struct SimulatorDeviceHeader<Actions: View>: View {
    var device: SimulatorDevice
    var resolution: CGSize?
    var orientation: SimulatorOrientation
    var pinnedLocation: SimulatorCoordinate?
    var onBack: () -> Void
    /// The verbs that act on this device, right-aligned in the same band. Declared last so a caller
    /// can pass them as a trailing closure — and AFTER `onBack` so an unlabelled one still binds to
    /// the view builder rather than to the navigation handler.
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            PlateIconButton(symbol: .chevronLeft) { onBack() }
                .help(SimulatorPresentation.backHelp)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space1) {
                    Text(device.name)
                        .font(.system(size: Slate.Typeface.title, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The runtime rides the TITLE, not the facts line: it is half of what names a
                    // device — two iPhone 17 Pros differ by nothing else — and a caption reading
                    // "iPhone 17 Pro · iOS 26.5" is how every simulator UI writes it. On the facts
                    // line it was one dot-separated figure among four, which is where the thing you
                    // are actually looking for goes to hide.
                    Text(device.runtime)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                SlateFactLine(facts: facts)
            }
            // The identity yields its width first: the verbs are fixed-size plates and the name
            // truncates, which is the right way round — a clipped rail would put a verb somewhere
            // the pointer cannot reach, while a clipped name is still a name.
            .layoutPriority(-1)
            actions()
        }
        // Keyed on WHICH facts are present, not on their values: a resolution arriving with the first
        // decoded frame, or a position being pinned, adds a fact mid-sentence, and the line should
        // grow into it rather than snap.
        .animation(Slate.Anim.smallFade, value: facts.map(\.id))
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
        // NO RULE UNDER IT (user-directed 2026-08-04) and no tone change either: the header and the
        // stage are the SAME ground now (ONE ISLAND — the panel sinks), so this line simply sits in
        // the field above the device, which is what a caption does. The hairline that used to be here
        // was a second rule landing a few points under the tab strip's, and that is what made the top
        // of the panel read as a stack of bands rather than as a caption over a device. (Until
        // 2026-08-08 the edge was carried by the stage opening one step up in light — MERIDIAN L5.
        // See ``SimulatorStageView`` for why that split retired.)
        .background(Slate.Surface.field)
    }

    /// The line's CONTENT is the shared fold's; drawing it is this half's. Which facts are present,
    /// their order, which of them hide their label and what Copy hands over are all recorded at
    /// ``SimulatorPresentation/facts(device:resolution:orientation:pinnedLocation:)``.
    private var facts: [SlateFact] {
        SimulatorPresentation.facts(
            device: device, resolution: resolution, orientation: orientation,
            pinnedLocation: pinnedLocation,
        ).map(SlateFact.init)
    }
}

extension SlateFact {
    /// A shared fact, drawn on this half's ladder.
    ///
    /// The BRIDGE is the whole of what a hue costs: `SlopDeskSlate` depends on `SlopDeskDevicePanels`,
    /// so a token cannot descend to where the fold lives, and a ROLE comes up instead. Four lines here,
    /// four in `MacSimulatorInk`, and no third place either can drift from.
    ///
    /// `@MainActor` rides along with the hue it reads — see ``SimulatorInk/slateColor``.
    @MainActor
    init(_ fact: SimulatorFact) {
        self.init(
            fact.label, fact.text, copies: fact.copies, tint: fact.ink.slateColor,
            isMeasured: fact.isMeasured, showsLabel: fact.showsLabel,
        )
    }
}

extension SimulatorInk {
    /// The phone's resolution of the panel's one ink vocabulary. ``SimulatorInk/alarm`` is the ONLY
    /// colour this panel has — see the enum's own note for the three surfaces that each broke that rule
    /// independently before 2026-08-04.
    ///
    /// `@MainActor` for the reason the Android twin records: `Slate.Text` is main-actor state, and a
    /// computed property on a `Sendable` enum is nonisolated by default, so without it this reads as a
    /// background thread asking for the theme's current hue.
    @MainActor
    var slateColor: Color {
        switch self {
        case .primary: Slate.Text.primary
        case .secondary: Slate.Text.secondary
        case .tertiary: Slate.Text.tertiary
        case .alarm: Slate.StatusInk.err
        }
    }
}
#endif
