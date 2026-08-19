// MacSimulatorLocationPopover — where the device thinks it is, in AppKit (docs/56 stage D,
// increment 52a).
//
// A POPOVER, not a drawer. Unlike the console this is set-and-forget: the value is applied once and
// then matters as a FACT, not as a stream, so it belongs somewhere that closes. What stays visible
// afterwards is the header's readout — which is the whole reason the header carries it.
//
// PRESETS FIRST, field second. The realistic use is "run this as if it were somewhere else", and the
// honest answer to that is a short list of somewhere-elses (``SimulatorPlace/all``, deliberately short:
// a picker of two hundred cities is a search problem). The field exists because the other real use is
// a coordinate pasted out of a map, and no list can anticipate that one.
//
// THE BUTTON IS THE ONLY SUBMIT PATH, on both halves and for the same reason: the plate is the chrome's
// search input (``SlateNativeSearchField``), which reports text as it changes and has no return action
// to hang a submit on. Giving this one field a bespoke return handler would make it a different control
// from every other field in the app that looks exactly like it.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSimulatorLocationPopover: NSViewController, NSPopoverDelegate {
    private let pinned: SimulatorCoordinate?
    private let apply: (SimulatorCoordinate?) -> Void

    /// Owned rather than handed in, so the one thing this surface must be able to do to itself —
    /// close on apply — needs no back-channel to whatever presented it.
    private let popover = NSPopover()

    private var field: NSTextField?
    private let setButton = NSButton()

    init(pinned: SimulatorCoordinate?, apply: @escaping (SimulatorCoordinate?) -> Void) {
        self.pinned = pinned
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// `.transient` so a click anywhere else closes it: this is a set-and-forget control, and a
    /// popover that had to be dismissed deliberately would be a second thing to do after the one thing.
    func show(from anchor: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// ⚠️ THE CONTENT IS DROPPED ON CLOSE, and it has to be. Owning the popover while BEING its
    /// `contentViewController` is a reference cycle, so a popover left holding its content would leak
    /// this controller and its whole view tree once per open. `delegate` is the weak side of the pair,
    /// so it is safe to be our own.
    func popoverDidClose(_: Notification) {
        popover.contentViewController = nil
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = macSimulatorCapsLabel(SimulatorPresentation.Location.title)

        let places = NSStackView(views: SimulatorPlace.all.map(row))
        places.orientation = .vertical
        places.alignment = .leading
        places.spacing = 0

        let rule = NSBox()
        rule.boxType = .separator

        let stack = NSStackView(views: [title, places, rule, entry(), footer()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            // FIXED, for the reason the notification card is: a popover that hugs its content is a
            // popover whose width is decided by whichever row happens to hold the longest string, so
            // the same control opens at a different size on different data.
            root.widthAnchor.constraint(equalToConstant: Slate.Metric.popoverWidth),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Slate.Metric.space3),
            stack.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Slate.Metric.space3),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Slate.Metric.space3),
        ])
        for wide in stack.arrangedSubviews {
            wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = root
    }

    // MARK: The presets

    private func row(_ place: SimulatorPlace) -> NSView {
        let shell = MacSimulatorRowShell()
        shell.active = pinned == place.coordinate
        shell.onTap = { [weak self] in self?.send(place.coordinate) }
        shell.content.addArrangedSubview(macSimulatorLabel(
            place.name, size: Slate.Typeface.base, color: Slate.Native.Text.primary,
        ))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        shell.content.addArrangedSubview(spacer)
        // The readout is MEASURED, so it speaks the instrument voice, and it yields its width first —
        // the name is what the reader is picking from.
        let readout = macSimulatorLabel(
            place.coordinate.readout, size: Slate.Typeface.small,
            color: Slate.Native.Text.tertiary, mono: true,
        )
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shell.content.addArrangedSubview(readout)
        return shell
    }

    // MARK: The typed coordinate

    private func entry() -> NSView {
        let plate = MacSimulatorSearchPlate(
            placeholder: SimulatorPresentation.Location.placeholder,
        ) { [weak self] _ in self?.refreshSetButton() }

        setButton.title = SimulatorPresentation.Location.set
        setButton.isBordered = false
        setButton.font = .systemFont(ofSize: Slate.Typeface.footnote)
        setButton.target = self
        setButton.action = #selector(setTyped)
        setButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [plate, setButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        typedPlate = plate
        refreshSetButton()
        return row
    }

    private var typedPlate: MacSimulatorSearchPlate?

    private var parsed: SimulatorCoordinate? {
        guard let typedPlate else { return nil }
        return SimulatorCoordinate.parse(typedPlate.query)
    }

    /// Disabled until the text parses, and the ink says so before the pointer does — a Set that looks
    /// live over an unparseable string is the mis-pin this field's whole validation exists to stop.
    private func refreshSetButton() {
        let ready = parsed != nil
        setButton.isEnabled = ready
        setButton.contentTintColor = ready ? Slate.Native.accent : Slate.Native.Text.tertiary
    }

    @objc
    private func setTyped() {
        guard let parsed else { return }
        send(parsed)
    }

    // MARK: The footer

    /// Says what is true now and offers the one verb that undoes it. "Clear" is ABSENT while nothing is
    /// pinned, because a control that undoes nothing is a control that has to be reasoned about before
    /// it is ignored.
    private func footer() -> NSView {
        guard let pinned else {
            return macSimulatorLabel(
                SimulatorPresentation.Location.live, size: Slate.Typeface.small,
                color: Slate.Native.Text.tertiary,
            )
        }
        let readout = macSimulatorLabel(
            SimulatorPresentation.Location.pinned(pinned), size: Slate.Typeface.small,
            color: Slate.Native.Text.tertiary,
        )
        let clear = NSButton(
            title: SimulatorPresentation.Location.clear, target: self, action: #selector(clearPin),
        )
        clear.isBordered = false
        clear.font = .systemFont(ofSize: Slate.Typeface.footnote)
        // The panel's ONE alarm role, resolved. Clearing a pin is the destructive half of this surface
        // and the only thing in it that earns a colour.
        clear.contentTintColor = MacSimulatorInk.color(.alarm)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [readout, spacer, clear])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        return row
    }

    @objc
    private func clearPin() { send(nil) }

    /// Applying CLOSES the popover. The result is reported in the header and in the window's own
    /// notification card, so keeping it open would leave a sheet over the device to say something
    /// already said twice behind it.
    private func send(_ coordinate: SimulatorCoordinate?) {
        apply(coordinate)
        popover.performClose(nil)
    }
}
