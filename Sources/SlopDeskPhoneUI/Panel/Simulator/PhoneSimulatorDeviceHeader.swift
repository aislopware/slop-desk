// PhoneSimulatorDeviceHeader — what device this is, and what is true about it right now.
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
//
// IT IS A TITLE, not another row. The name takes the `title` rung, the one size in the system whose job
// is to outrank the content it names, and the facts sit under it on the name's own left rail. Nothing
// else in the panel is allowed that size, which is what makes it mean "this is the subject".
//
// THE BACK CONTROL LIVES HERE rather than in the toolbar. The toolbar is verbs that act on the
// device; leaving the device is navigation, and putting it beside the device's own name is where
// every split view in the app already puts it.
//
// ⚠️ THE VERBS DO NOT, and that is the ONE place this band parts from `MacSimulatorDeviceHeader`.
// They landed in the Mac's header because that band's trailing half was empty at every panel size — a
// ~700pt column with a ~180pt name in it. A phone panel is 390pt wide, and the same rail is ten
// `heightControl` plates plus their spacings: ~280pt, which leaves sixty for the device's name. So the
// rail gets a strip of its own directly under this band (``PhoneSimulatorStageView``), which is the
// arrangement the Mac's own reasoning arrives at once the width it assumed is gone. The stage below is
// still nothing but the device.
//
// NO COLOURED STATUS INDICATOR, here or anywhere else in the panel (user-directed 2026-08-04). The rule
// it leaves behind is worth stating once for the whole panel: a hue means SOMETHING IS WRONG, and
// nothing else. Healthy states ride luminance and weight. NO "Connecting…" caption either — it
// captioned the state from OUTSIDE the thing it was about, and it had no end. The word belongs on the
// empty rectangle, where the stage's own veil puts it.
//
// WHICH facts are present and in what order is
// ``SimulatorPresentation/facts(device:resolution:orientation:pinnedLocation:)``'s. What stays here is
// the DRAWING, plus the four lines that turn a role into a hue, which cannot descend.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneSimulatorDeviceHeader: UIView {
    /// Assigning re-labels the band in place. A device switch keeps ONE header rather than minting a
    /// second: the band's shape never changes, only the words in it, and a remount would drop the
    /// fact line's own interactions on every poll that renamed a state string.
    var reading: Reading {
        didSet {
            guard reading != oldValue else { return }
            relabel()
        }
    }

    /// Everything the band draws, as one value — so a caller cannot set a name and a resolution from
    /// two different devices in two statements.
    struct Reading: Equatable {
        var device: SimulatorDevice
        var resolution: CGSize?
        var orientation: SimulatorOrientation
        var pinnedLocation: SimulatorCoordinate?
    }

    private let name = UILabel()
    private let runtime = UILabel()
    private let facts = SlateFactLineView()

    init(reading: Reading, onBack: @escaping () -> Void) {
        self.reading = reading
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let back = SlatePlateIconButton(symbol: .chevronLeft, action: onBack)
        back.slateHelp(SimulatorPresentation.backHelp)

        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: Slate.Typeface.title, weight: .semibold)
        name.textColor = Slate.Native.Text.primary
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        // The NAME is what yields: the runtime is short and fixed, the plate is fixed, and a clipped
        // name is still a name.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The runtime rides the TITLE, not the facts line: it is half of what names a device — two
        // iPhone 17 Pros differ by nothing else — and a caption reading "iPhone 17 Pro · iOS 26.5" is
        // how every simulator UI writes it. On the facts line it was one dot-separated figure among
        // four, which is where the thing you are actually looking for goes to hide.
        runtime.translatesAutoresizingMaskIntoConstraints = false
        runtime.font = .systemFont(ofSize: Slate.Typeface.footnote)
        runtime.textColor = Slate.Native.Text.tertiary
        runtime.numberOfLines = 1
        runtime.setContentCompressionResistancePriority(.required, for: .horizontal)
        runtime.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [name, runtime])
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Slate.Metric.space1

        // Spacing 2, NOT a ladder rung: the facts are the title's own caption and sit on its baseline
        // rail, so the gap is optical rather than structural — `space1` here reads as a second row.
        let identity = UIStackView(arrangedSubviews: [titleRow, facts])
        identity.translatesAutoresizingMaskIntoConstraints = false
        identity.axis = .vertical
        identity.alignment = .leading
        identity.spacing = 2

        let row = UIStackView(arrangedSubviews: [back, identity])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])

        // NO RULE UNDER IT and no tone change either: the header and the stage are the SAME ground
        // (ONE ISLAND — the panel sinks), so this line simply sits in the field above the device,
        // which is what a caption does.
        backgroundColor = Slate.Native.Surface.field
        relabel()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The line's CONTENT is the shared fold's; drawing it is this half's. Which facts are present,
    /// their order, which of them hide their label and what Copy hands over are all recorded at
    /// ``SimulatorPresentation/facts(device:resolution:orientation:pinnedLocation:)``.
    private func relabel() {
        name.text = reading.device.name
        runtime.text = reading.device.runtime
        let shown = SimulatorPresentation.facts(
            device: reading.device, resolution: reading.resolution,
            orientation: reading.orientation, pinnedLocation: reading.pinnedLocation,
        ).map { fact in
            SlateFact(
                fact.label, fact.text, copies: fact.copies,
                tint: PhoneSimulatorInk.color(fact.ink),
                isMeasured: fact.isMeasured, showsLabel: fact.showsLabel,
            )
        }
        // ⚠️ Keyed on WHICH facts are present, not on their values. A resolution arriving with the
        // first decoded frame, or a position being pinned, adds a fact mid-sentence and the line should
        // grow into it; a re-measure that changed one digit must not fade the whole run.
        // ``SlateFactLineView`` is unanimated on assignment by design, so the beat is spent HERE.
        guard shown.map(\.id) != facts.facts.map(\.id) else {
            facts.facts = shown
            return
        }
        UIView.transition(
            with: facts, duration: Slate.Motion.smallFade.duration, options: .transitionCrossDissolve,
        ) { [facts] in
            facts.facts = shown
        }
    }
}
#endif
