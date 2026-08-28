// PhoneAndroidDeviceHeader — what device this is, and what is true about it right now.
//
// The band above the stage: the way back, the device's name, the facts about it, and the verbs that
// act on it. ``SlopDeskMacUI/MacAndroidDeviceHeader`` draws the same band in AppKit. WHICH facts a
// device has, in what order, and which of them was read off a machine is
// ``AndroidPresentation/facts(for:)`` — this file only turns that list into a ``SlateFactLineView``,
// which is a two-line map from ``AndroidFact`` and exactly the amount of translation an ink ROLE costs.
//
// Every rule the simulator header records applies here unchanged — the title outranks the content it
// names, the back control lives beside the name rather than in the toolbar, no coloured status
// indicator, no connecting caption.
//
// WHAT DIFFERS IS THAT THE FACTS ARE ACTUALLY KNOWN. `docs/47` explains that a simulator's header can
// print a resolution only once the decoder has told it one, because the server knows four things about
// a device and geometry is not among them. Android reports its screen size, its density and its API
// level for a device that has never booted (`docs/48`: an AVD's `config.ini` is its DEFINITION), so
// this line is real from the moment the list arrives — and the STREAM's size is deliberately not
// printed beside them. The panel mirrors at a cap (``AndroidSidebarModel/streamMaxSize``), so the
// encoded size is a fact about this panel's request and not about the device; printing both would be
// two resolutions in one line, one of them wrong for every purpose anyone would use it for.
//
// BUILT ONCE PER DEVICE, never mutated in place. The stage rebuilds this band when its own signature
// changes, which is the same gate the Mac's ``MacAndroidStageView`` applies: a header that reassigned
// its labels on every observation callback would re-run a fact line's whole teardown for a log row
// arriving in the drawer below it.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import UIKit

@MainActor
final class PhoneAndroidDeviceHeader: UIView {
    /// - Parameter actions: the verbs that act on this device, right-aligned in the same band. A view
    ///   rather than a builder: UIKit's slot is a mounted object, so the toolbar is made once by the
    ///   stage that owns its latches and handed over, instead of being re-invoked per pass.
    init(device: AndroidDevice, actions: UIView, onBack: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // No rule under it and no tone change: header and stage share the ground (ONE ISLAND, law 1),
        // so this reads as a caption over the device.
        backgroundColor = Slate.Native.Surface.field

        let back = SlatePlateIconButton(symbol: .chevronLeft) { onBack() }
        back.slateHelp(AndroidPresentation.backHelp)

        let name = UILabel()
        name.text = device.name
        name.font = .systemFont(ofSize: Slate.Typeface.title, weight: .semibold)
        name.textColor = PhoneAndroidInk.color(.primary)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The platform version rides the TITLE, not the facts line, for the reason the simulator header
        // gives its runtime: it is half of what NAMES a device. Two Pixel 7 AVDs differ by nothing
        // else, and on the facts line it would be one dot-separated figure among four.
        let version = UILabel()
        version.text = device.versionLabel
        version.font = .systemFont(ofSize: Slate.Typeface.footnote)
        version.textColor = PhoneAndroidInk.color(.tertiary)
        version.numberOfLines = 1
        version.translatesAutoresizingMaskIntoConstraints = false
        version.setContentCompressionResistancePriority(.required, for: .horizontal)
        version.setContentHuggingPriority(.required, for: .horizontal)
        version.isHidden = device.versionLabel == nil

        let facts = SlateFactLineView()
        // The shared fact list, with its ink ROLE resolved to this half's hues. Everything else about a
        // fact — its label, its abbreviation, the whole value its Copy hands over, and whether it was
        // MEASURED — travels unchanged, because none of those is a drawing decision.
        facts.facts = AndroidPresentation.facts(for: device).map {
            SlateFact(
                $0.label, $0.text, copies: $0.copies, tint: PhoneAndroidInk.color($0.ink),
                isMeasured: $0.isMeasured, showsLabel: $0.showsLabel,
            )
        }

        let identity = UIView()
        identity.translatesAutoresizingMaskIntoConstraints = false
        for view in [name, version, facts] { identity.addSubview(view) }

        actions.translatesAutoresizingMaskIntoConstraints = false
        for view in [back, identity, actions] { addSubview(view) }

        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            back.centerYAnchor.constraint(equalTo: centerYAnchor),

            identity.leadingAnchor.constraint(
                equalTo: back.trailingAnchor, constant: Slate.Metric.space2,
            ),
            identity.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            identity.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),

            // The identity yields its width first: the verbs are fixed-size plates and the name
            // truncates, which is the right way round — a clipped rail would put a verb somewhere the
            // finger cannot reach, while a clipped name is still a name.
            actions.leadingAnchor.constraint(
                greaterThanOrEqualTo: identity.trailingAnchor, constant: Slate.Metric.space2,
            ),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),

            name.leadingAnchor.constraint(equalTo: identity.leadingAnchor),
            name.topAnchor.constraint(equalTo: identity.topAnchor),
            // FIRST BASELINE, not centre: the two labels are four points apart in size, and a version
            // centred against a title sits visibly high.
            version.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            version.leadingAnchor.constraint(
                equalTo: name.trailingAnchor, constant: Slate.Metric.space1,
            ),
            version.trailingAnchor.constraint(lessThanOrEqualTo: identity.trailingAnchor),

            // `2`, and deliberately not a rung: the name and its facts are ONE object, and the
            // smallest space on the ladder already reads as a gap between two.
            facts.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            facts.leadingAnchor.constraint(equalTo: identity.leadingAnchor),
            facts.trailingAnchor.constraint(lessThanOrEqualTo: identity.trailingAnchor),
            facts.bottomAnchor.constraint(equalTo: identity.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif
