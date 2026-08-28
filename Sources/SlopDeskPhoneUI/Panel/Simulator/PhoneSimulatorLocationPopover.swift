// PhoneSimulatorLocationPopover — where the device thinks it is.
//
// A POPOVER, not a drawer. Unlike the console this is set-and-forget: the value is applied once and
// then matters as a fact, not as a stream, so it belongs somewhere that closes. What stays visible
// afterwards is the header's readout — which is the whole reason the header carries it.
//
// PRESETS FIRST, field second. The realistic use is "run this as if it were somewhere else", and the
// honest answer to that is a short list of somewhere-elses. The field exists because the other real use
// is a coordinate pasted out of a map, and no list can anticipate that one.
//
// ⚠️ IT STAYS A POPOVER IN THE COMPACT SIZE CLASS, which costs one delegate method. UIKit adapts a
// popover to a full-height sheet on a phone by default, and a sheet is the wrong shape twice over here:
// the thing being positioned is the DEVICE, and a sheet covers it, so the reader loses the object the
// setting is about at the moment they change it. The popover is 260pt of a 390pt panel, anchored to the
// plate that opened it, and the device stays visible beside it. (The deleted SwiftUI half took the
// default adaptation, which is how it became a sheet; the width token it declared —
// ``Slate/Metric/popoverWidth`` — is the one it never got to use.)
//
// The five words and the live/pinned fold are ``SimulatorPresentation/Location``'s — the fold in
// particular, because "Clear" being ABSENT rather than disabled while nothing is pinned is a decision,
// and a renderer holding two loose labels is a renderer that can draw the verb that undoes nothing.

#if os(iOS)
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhoneSimulatorLocationPopover: UIViewController, UIPopoverPresentationControllerDelegate {
    private let pinned: SimulatorCoordinate?
    private let apply: (SimulatorCoordinate?) -> Void

    private let field = UIView()
    private let entry: SlateSearchLine
    private let set = UIButton(type: .custom)
    private var typed = ""

    init(pinned: SimulatorCoordinate?, apply: @escaping (SimulatorCoordinate?) -> Void) {
        self.pinned = pinned
        self.apply = apply
        entry = SlateSearchLine(placeholder: SimulatorPresentation.Location.placeholder)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        preferredContentSize = CGSize(width: Slate.Metric.popoverWidth, height: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The one line that keeps this a popover on a phone. See the header.
    func adaptivePresentationStyle(
        for _: UIPresentationController, traitCollection _: UITraitCollection,
    ) -> UIModalPresentationStyle { .none }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.attributedText = NSAttributedString(
            string: SimulatorPresentation.Location.title,
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold),
                .kern: Slate.Typeface.instrumentTracking,
                .foregroundColor: Slate.Native.State.header,
            ],
        )

        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = Slate.Native.Line.divider
        rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline).isActive = true

        let column = UIStackView(arrangedSubviews: [title] + places() + [rule, plate(), footer()])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Slate.Metric.space2
        // The preset rows are a RUN, not a spaced list: each carries its own row shell with its own
        // hairline, and a gap between them would turn one list into six cards.
        for row in column.arrangedSubviews where row is SlateListRowView {
            column.setCustomSpacing(0, after: row)
        }
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: Slate.Metric.space3),
            column.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Slate.Metric.space3,
            ),
            column.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Slate.Metric.space3),
        ])
        refreshSet()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The popover sizes to its content, and its content is a column of rows whose height is only
        // known once they have laid out. Written back rather than guessed, so a preset list that grows
        // does not need this number edited.
        let height = view.systemLayoutSizeFitting(
            CGSize(width: Slate.Metric.popoverWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel,
        ).height
        let wanted = CGSize(width: Slate.Metric.popoverWidth, height: height)
        guard preferredContentSize != wanted else { return }
        preferredContentSize = wanted
    }

    private func places() -> [UIView] {
        SimulatorPlace.all.map { place in
            let name = UILabel()
            name.translatesAutoresizingMaskIntoConstraints = false
            name.font = .systemFont(ofSize: Slate.Typeface.base)
            name.textColor = Slate.Native.Text.primary
            name.numberOfLines = 1

            let readout = UILabel()
            readout.translatesAutoresizingMaskIntoConstraints = false
            readout.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .regular)
            readout.textColor = Slate.Native.Text.tertiary
            readout.numberOfLines = 1
            readout.text = place.coordinate.readout
            readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            name.text = place.name
            let row = SlateListRowView()
            row.title = name
            row.titleTrailing = readout
            row.active = pinned == place.coordinate
            row.onTap = { [weak self] in self?.send(place.coordinate) }
            return row
        }
    }

    /// The button is the only submit path. ``SlateSearchLine`` reports text as it changes and has no
    /// return action to hang a submit on — and giving this one field a bespoke return handler would make
    /// it a different control from every other field in the app that looks exactly like it.
    private func plate() -> UIView {
        entry.onTextChange = { [weak self] text in
            self?.typed = text
            self?.refreshSet()
        }
        set.titleLabel?.font = .systemFont(ofSize: Slate.Typeface.footnote)
        set.setTitle(SimulatorPresentation.Location.set, for: .normal)
        set.setContentHuggingPriority(.required, for: .horizontal)
        set.addAction(UIAction { [weak self] _ in
            guard let self, let parsed = SimulatorCoordinate.parse(typed) else { return }
            send(parsed)
        }, for: .touchUpInside)

        let run = UIStackView(arrangedSubviews: [entry, set])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space1

        field.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(run)
        field.slateChromeFieldPlate()
        NSLayoutConstraint.activate([
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            run.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Slate.Metric.space2),
            run.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -Slate.Metric.space2),
            run.topAnchor.constraint(equalTo: field.topAnchor),
            run.bottomAnchor.constraint(equalTo: field.bottomAnchor),
        ])
        return field
    }

    private func refreshSet() {
        let parsed = SimulatorCoordinate.parse(typed) != nil
        set.isEnabled = parsed
        set.setTitleColor(parsed ? Slate.Native.State.accent : Slate.Native.Text.tertiary, for: .normal)
        set.setTitleColor(Slate.Native.Text.tertiary, for: .disabled)
    }

    /// The footer says what is true now and offers the one verb that undoes it. "Clear" is absent while
    /// nothing is pinned, because a control that undoes nothing is a control that has to be reasoned
    /// about before it is ignored.
    private func footer() -> UIView {
        let caption = UILabel()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: Slate.Typeface.small)
        caption.textColor = Slate.Native.Text.tertiary
        caption.numberOfLines = 1

        guard let pinned else {
            caption.text = SimulatorPresentation.Location.live
            let run = UIStackView(arrangedSubviews: [caption, UIView()])
            run.translatesAutoresizingMaskIntoConstraints = false
            run.axis = .horizontal
            run.alignment = .center
            run.spacing = Slate.Metric.space1
            return run
        }
        caption.text = SimulatorPresentation.Location.pinned(pinned)
        let clear = UIButton(type: .custom)
        clear.titleLabel?.font = .systemFont(ofSize: Slate.Typeface.footnote)
        clear.setTitle(SimulatorPresentation.Location.clear, for: .normal)
        clear.setTitleColor(Slate.Native.StatusInk.err, for: .normal)
        clear.setContentHuggingPriority(.required, for: .horizontal)
        clear.addAction(UIAction { [weak self] _ in self?.send(nil) }, for: .touchUpInside)

        let run = UIStackView(arrangedSubviews: [caption, UIView(), clear])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space1
        return run
    }

    /// Applying closes the popover. The result is reported in the header and in the app's notification
    /// card, so keeping it open would leave a card over the device to say something already said twice
    /// behind it.
    private func send(_ coordinate: SimulatorCoordinate?) {
        apply(coordinate)
        dismiss(animated: true)
    }
}
#endif
