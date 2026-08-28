// PhoneAndroidStageView — the whole mirroring surface: what device this is, the device itself, what
// you can do to it, and what it is saying.
//
// ``SlopDeskMacUI/MacAndroidStageView`` is the Mac's half, in AppKit. What is NOT duplicated is
// anything a reader reads or a state decides: every word here, the veil's fold, the toolbar's two
// trays and the verb→model table are ``AndroidPresentation``'s and are asked for rather than spelled.
//
// THREE BANDS, top to bottom, exactly as the simulator stage has them and for the same reasons: the
// top bar names the thing the other two are about and carries the verbs that act on it; the device is
// the lit content; the console is what the device just said, so it goes below rather than beside and
// the tap-watch-read loop stays one column. ONE surface under all three: the panel sinks to the
// window's cream ground (ONE ISLAND, law 1) and hairlines tell the bands apart.
//
// NO BEZEL, and it is not an omission. The simulator panel seats its stream inside the real device
// body because `baguette` serves per-model chrome artwork. Nothing equivalent exists for Android: the
// device set is every phone ever made, and drawing a generic rounded rectangle around the frame would
// be a claim about a device's shape that is right for none of them. What the bezel BOUGHT there — the
// side buttons under the pointer where the eye expects them — is bought here by the toolbar, which is
// where those buttons already had to live anyway.
//
// THE TOOLBAR IS THE THREE NAVIGATION KEYS PLUS WHAT HAS NO GESTURE, and which verbs those are is
// ``AndroidPresentation/navigationTray`` and ``AndroidPresentation/actionTray`` — a tray is an ordered
// list, and an ordering drawn twice from prose drifts. Everything a finger can already do — pulling
// the shade down, swiping between apps — is deliberately absent from both: `scrcpy` injects real touch
// events, so those gestures work on the frame itself, and a plate that duplicates a gesture is a plate
// that can be pressed by mistake.
//
// NO DROP TARGET (yet). The simulator stage installs a dropped `.app` because its server routes files
// by extension. The equivalent here is `adb install`, which is a different verb with a different
// failure mode (a signature mismatch, a downgrade, an ABI the device cannot run) and deserves its own
// reporting rather than being smuggled in as a drop.
//
// THIS PANEL DRAWS NO BANNER. Every report leaves through the app's notification card; the announcement
// lives on the surface that outlives both the stage and the list. What stays here is the STATE, which a
// notification cannot carry: a mirror with no video is drawn on the stage itself, where the ambiguous
// empty rectangle is.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore // `ObservationFollow` — this stage re-follows, so it needs the replacing arm
import SlopDeskDevicePanels
import SlopDeskSlate
import UIKit

@MainActor
final class PhoneAndroidStageView: UIView {
    private let model: AndroidSidebarModel
    private let onBack: () -> Void

    private let headerSlot = UIView()
    private let bed = UIView()
    private let consoleSlot = UIView()
    private var consoleHeight: NSLayoutConstraint!

    private var header: PhoneAndroidDeviceHeader?
    private var screen: PhoneAndroidScreenView?
    private var console: PhoneAndroidConsoleView?
    private var veil: UIView?

    /// The veil's own state, which is the model's loading state DELAYED — see
    /// ``AndroidPresentation/veilDelay``.
    private var showsLoading = false
    /// The device's own backlight, as last set from here. Local because `scrcpy` has no read side for
    /// it: this is what the next press toggles, not a claim about the device.
    private var isDisplayOff = false

    /// The plates, by the verb they run, so a latch can be relit without rebuilding the toolbar the
    /// finger is on.
    private var plates: [AndroidStageAction: SlatePlateIconButton] = [:]
    private var keyboardPlate: SlatePlateIconButton?

    /// What the header last drew. A header rebuild tears down a fact line and both labels, and a log
    /// row arriving in the drawer below must not pay for that.
    private var headerSignature: String?
    /// Which device the mounted mirror belongs to. Switching devices MINTS A FRESH VIEW rather than
    /// reconfiguring one — feeding a second stream's frames into a layer configured for the first
    /// one's parameter sets is a decoder error, not a redraw.
    private var mounted: String?
    private var reading: AndroidStageReading?

    /// The veil's delay, running. Restarted ONLY on an edge of `isAwaitingStream` — that is what
    /// `.task(id:)` meant, and re-arming it on every observation callback would turn a 600 ms grace
    /// into a veil that never appears.
    private var veilTask: Task<Void, Never>?
    private var veilKey: Bool?

    /// The live arm. Held because ``follow()`` has two entry points and the second must DISPLACE the
    /// first; ``unmount()`` ends it outright, which is hazard 2's counter in its explicit spelling.
    private var stageFollow: ObservationFollow?

    init(model: AndroidSidebarModel, onBack: @escaping () -> Void) {
        self.model = model
        self.onBack = onBack
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.field

        for band in [headerSlot, bed, consoleSlot] {
            band.translatesAutoresizingMaskIntoConstraints = false
            addSubview(band)
        }
        // The drawer is CLIPPED, so the console slides out of a band that is already zero-height rather
        // than drawing over the picture on its way in.
        consoleSlot.clipsToBounds = true
        consoleHeight = consoleSlot.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            headerSlot.topAnchor.constraint(equalTo: topAnchor),
            headerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),

            bed.topAnchor.constraint(equalTo: headerSlot.bottomAnchor),
            bed.leadingAnchor.constraint(equalTo: leadingAnchor),
            bed.trailingAnchor.constraint(equalTo: trailingAnchor),

            consoleSlot.topAnchor.constraint(equalTo: bed.bottomAnchor),
            consoleSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            consoleSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            consoleSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
            consoleHeight,
        ])

        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The stage is going away — a drill back to the list, a tab switch, or the panel closing. The
    /// mirror holds live gesture state and a send closure into a socket that is about to be gone, and
    /// the veil holds a sleeping `Task`. Both are torn down here rather than in `deinit`, because a
    /// view that is animating out is still alive and must already be inert.
    func unmount() {
        stageFollow?.stop()
        veilTask?.cancel()
        veilTask = nil
        screen?.unmount()
    }

    // MARK: Following the model

    /// The re-arm is ``ObservationFollow``'s now, not this file's. What stays this file's obligation is
    /// the `read` block's CONTENT: every tracked read is inside it and none is conditional — a
    /// `hasVideo` read that only happened while a device was selected would stop observing the frame
    /// that ends the wait.
    ///
    /// ``DeviceSoftKeyboard/isTyping`` is read here for the same reason the model's flags are: the
    /// keyboard can go down by the system's own gesture, and a plate lit against a keyboard that is not
    /// there is worse than no plate.
    ///
    /// ⚠️ CALLED TWICE — from `init` and from ``waitOutVeil()`` — so it goes through
    /// ``ObservationFollow/arm(_:replacing:read:apply:)``. The generation counter this replaced was
    /// doing exactly that displacement by hand, and the Mac twin
    /// (`MacAndroidStageView`) is the proof it was load-bearing rather than ceremonial: that file has
    /// the same two entry points, never had the counter, and was arming a second permanent chain on
    /// every veil timeout until this conversion.
    private func follow() {
        stageFollow = ObservationFollow.arm(self, replacing: stageFollow) { view in
            (
                device: view.model.selectedDevice,
                selection: view.model.selection,
                isAwaiting: view.model.isAwaitingStream,
                hasVideo: view.model.hasVideo,
                streamSize: view.model.streamSize,
                isConsoleOpen: view.model.isConsoleOpen,
                isTyping: DeviceSoftKeyboard.shared.isTyping,
            )
        } apply: { view, reading in
            view.mountScreen(selection: reading.selection, streamSize: reading.streamSize)
            view.rebuildHeader(reading.device)
            view.setConsole(open: reading.isConsoleOpen)
            view.armVeil(isAwaiting: reading.isAwaiting)
            view.relight(isTyping: reading.isTyping)
            view.applyReading(AndroidPresentation.stage(
                showsLoading: view.showsLoading, hasSelection: reading.selection != nil,
                isAwaitingStream: reading.isAwaiting, hasVideo: reading.hasVideo,
                deviceIsRunning: reading.device?.isRunning,
            ))
        }
    }

    // MARK: The device

    private func mountScreen(selection: String?, streamSize: CGSize?) {
        guard selection != mounted else {
            screen?.videoSize = streamSize ?? .zero
            return
        }
        mounted = selection
        screen?.unmount()
        screen?.removeFromSuperview()
        screen = nil
        guard selection != nil else { return }

        let view = PhoneAndroidScreenView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.send = { [weak self] message in self?.model.send(message) }
        view.videoSize = streamSize ?? .zero
        bed.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: bed.topAnchor, constant: Slate.Metric.space3),
            view.bottomAnchor.constraint(equalTo: bed.bottomAnchor, constant: -Slate.Metric.space3),
            view.leadingAnchor.constraint(equalTo: bed.leadingAnchor, constant: Slate.Metric.space3),
            view.trailingAnchor.constraint(equalTo: bed.trailingAnchor, constant: -Slate.Metric.space3),
        ])
        // The sink REPLAYS: `scrcpy` sends its parameter sets and one IDR at the head of the stream and
        // then, on a quiet screen, nothing at all. A mirror that mounted a beat after the socket opened
        // would otherwise sit black until somebody touched it.
        model.frames.attach(view)
        screen = view
        // The veil must sit over the picture, so it is re-raised whenever a new picture is put under it.
        if let veil { bed.bringSubviewToFront(veil) }
    }

    // MARK: Identity

    private func rebuildHeader(_ device: AndroidDevice?) {
        let signature = device.map { "\($0.key)/\($0.state)/\($0.versionLabel ?? "")" }
        guard signature != headerSignature else { return }
        headerSignature = signature

        let outgoing = header
        header = nil
        plates = [:]
        keyboardPlate = nil

        if let device {
            let built = PhoneAndroidDeviceHeader(
                device: device, actions: toolbar(),
            ) { [weak self] in self?.onBack() }
            built.alpha = 0
            headerSlot.addSubview(built)
            NSLayoutConstraint.activate([
                built.topAnchor.constraint(equalTo: headerSlot.topAnchor),
                built.bottomAnchor.constraint(equalTo: headerSlot.bottomAnchor),
                built.leadingAnchor.constraint(equalTo: headerSlot.leadingAnchor),
                built.trailingAnchor.constraint(equalTo: headerSlot.trailingAnchor),
            ])
            header = built
        }
        // A device can leave the list under the panel, and the band it names goes with it. The band
        // FADES rather than being cut, which is the same beat the drill above it rides.
        let incoming = header
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) {
            incoming?.alpha = 1
            outgoing?.alpha = 0
        } completion: { _ in
            outgoing?.removeFromSuperview()
        }
    }

    // MARK: The toolbar

    /// Two trays: navigate it, then act on it. Loose plates in a row read as texture rather than as
    /// verbs, so each job takes a ``SlatePlateTray`` and the rail becomes two objects instead of eight.
    ///
    /// The console plate stays OFF the trays on purpose: it LATCHES, and a latched plate is drawn as a
    /// lit key, which reads as lit only against the panel's own tone. Sitting it on a tray would put a
    /// lit key inside a lit tray and cost exactly the signal it exists to carry.
    private func toolbar() -> UIView {
        let navigation = SlatePlateTray(AndroidPresentation.navigationTray.map { plate($0) })
        let actions = SlatePlateTray(AndroidPresentation.actionTray.map { plate($0) })

        // PHONE-ONLY, and loose beside the console plate for the same reason that one is: it LATCHES.
        // The mirror has always typed from a hardware keyboard, which is the whole story on a Mac and
        // only half of it here — a phone with no keys could tap, swipe and screenshot the device
        // without ever putting a character into it. (The tray's paste verb was the one way round it,
        // and pasting is not typing.) See ``DeviceSoftKeyboard``.
        let keyboard = SlatePlateIconButton(symbol: .keyboard) { DeviceSoftKeyboard.shared.toggle() }
        keyboard.slateHelp(DeviceSoftKeyboard.plateHelp)
        keyboardPlate = keyboard

        let run = UIStackView(arrangedSubviews: [
            navigation, actions, keyboard, plate(AndroidPresentation.consoleVerb),
        ])
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space3
        return run
    }

    /// One verb as a plate. The LATCH is the view's — `scrcpy` has no read side for the backlight and
    /// the drawer's own flag is the model's — and everything else about the control (its glyph, its
    /// sentence, what it does to the device) comes from below.
    private func plate(_ verb: AndroidStageVerb) -> SlatePlateIconButton {
        let latched = isLatched(verb.action)
        let plate = SlatePlateIconButton(symbol: verb.symbol(latched: latched))
        plate.active = latched
        plate.slateHelp(verb.help(latched: latched))
        plate.addAction(UIAction { [weak self] _ in self?.press(verb) }, for: .touchUpInside)
        plates[verb.action] = plate
        return plate
    }

    private func isLatched(_ action: AndroidStageAction) -> Bool {
        switch action {
        case .displayPower: isDisplayOff
        case .console: model.isConsoleOpen
        default: false
        }
    }

    /// Flip whichever latch this verb owns FIRST, then run it with the result — the actuator is told
    /// what the device should now do rather than what the button just did
    /// (``AndroidPresentation/run(_:on:isDisplayOff:)``).
    private func press(_ verb: AndroidStageVerb) {
        switch verb.action {
        case .displayPower:
            isDisplayOff.toggle()
        case .console:
            AndroidPresentation.run(verb.action, on: model)
            redraw(verb)
            return
        default:
            break
        }
        AndroidPresentation.run(verb.action, on: model, isDisplayOff: isDisplayOff)
        redraw(verb)
    }

    /// One plate's glyph, ink and sentence, after its latch moved. ⚠️ THE GLYPH IS A DIFFERENT SYMBOL
    /// for a latching verb (`AndroidStageVerb.symbol(latched:)`), which ``SlatePlateIconButton`` cannot
    /// swap on its own — its `active` covers the ink and the weight, not the image — so the plate is
    /// re-minted at the one place it can change.
    private func redraw(_ verb: AndroidStageVerb) {
        guard let old = plates[verb.action] else { return }
        let latched = isLatched(verb.action)
        old.slateHelp(verb.help(latched: latched))

        guard verb.symbol(latched: true) != verb.symbol(latched: false),
              let stack = old.superview as? UIStackView,
              let slot = stack.arrangedSubviews.firstIndex(of: old)
        else {
            // No glyph to swap, so the latch IS the whole change. `morphOn` moves the acknowledgement
            // from the press to the LANDING, which is what makes a chord or a menu row driving the same
            // flag read exactly like a tap on the plate.
            old.morphOn = latched
            old.active = latched
            return
        }
        // A plate's SYMBOL is fixed at `init` — `active` covers the ink and the weight, not the image —
        // so a verb whose glyph latches gets a fresh plate in the same slot of the same stack. The
        // toolbar's geometry never moves, and the new glyph arriving IS the acknowledgement, which is
        // why this branch does not also bounce.
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        let fresh = plate(verb)
        fresh.onTray = old.onTray
        stack.insertArrangedSubview(fresh, at: slot)
    }

    /// The keyboard plate, relit from the registry rather than from a press: the system's own dismiss
    /// gesture puts the keyboard down without the plate being touched.
    private func relight(isTyping: Bool) {
        keyboardPlate?.active = isTyping
    }

    // MARK: Output

    /// A fixed band under the device rather than a split the user drags: the device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting.
    private func setConsole(open: Bool) {
        guard open != (console != nil) else { return }
        if open {
            let built = PhoneAndroidConsoleView(model: model)
            consoleSlot.addSubview(built)
            NSLayoutConstraint.activate([
                built.leadingAnchor.constraint(equalTo: consoleSlot.leadingAnchor),
                built.trailingAnchor.constraint(equalTo: consoleSlot.trailingAnchor),
                built.topAnchor.constraint(equalTo: consoleSlot.topAnchor),
                built.heightAnchor.constraint(equalToConstant: Slate.Metric.heightDrawer),
            ])
            console = built
        }
        let outgoing = open ? nil : console
        if !open { console = nil }

        consoleHeight.constant = open ? Slate.Metric.heightDrawer : 0
        // The drawer's open/close is a LAYOUT change, so it rides the standard transaction the way
        // every other drill in this panel does.
        UIView.animate(withDuration: Slate.Motion.standard.duration) { [weak self] in
            self?.layoutIfNeeded()
        } completion: { _ in
            outgoing?.removeFromSuperview()
        }
    }

    // MARK: The stage's other two states

    /// Mirror the model's loading state into ``showsLoading``, late on the way up and immediate on the
    /// way down.
    ///
    /// ⚠️ RESTARTED ONLY ON AN EDGE. The identity check is the whole thing: cancelling and re-arming on
    /// every observation callback would re-arm the delay each time a log line arrived, and the veil
    /// would never appear at all. The delay itself is measured and lives with the other half of the
    /// decision (``AndroidPresentation/veilDelay``), which is `rust/slopdesk-devicepanel`'s number.
    private func armVeil(isAwaiting: Bool) {
        guard isAwaiting != veilKey else { return }
        veilKey = isAwaiting
        veilTask?.cancel()
        veilTask = Task { [weak self] in
            guard let state = await PhoneDevicePanelChrome.loadingVeilState(
                isAwaiting: isAwaiting, after: AndroidPresentation.veilDelay,
            ) else { return }
            guard let self else { return }
            showsLoading = state
            follow()
        }
    }

    /// A stage with no picture on it says which of the two reasons that is. Covering the whole BED
    /// rather than captioning it from the header is the point: the ambiguous object IS the empty
    /// rectangle, and an empty rectangle and a dead stream are pixel-identical. It stops at the header,
    /// which keeps the way out reachable while it is up.
    private func applyReading(_ next: AndroidStageReading) {
        guard next != reading else { return }
        reading = next

        let outgoing = veil
        veil = nil
        if let built = veilBody(next) {
            built.alpha = 0
            bed.addSubview(built)
            NSLayoutConstraint.activate([
                built.topAnchor.constraint(equalTo: bed.topAnchor),
                built.bottomAnchor.constraint(equalTo: bed.bottomAnchor),
                built.leadingAnchor.constraint(equalTo: bed.leadingAnchor),
                built.trailingAnchor.constraint(equalTo: bed.trailingAnchor),
            ])
            veil = built
        }
        let incoming = veil
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) {
            incoming?.alpha = 1
            outgoing?.alpha = 0
        } completion: { _ in
            outgoing?.removeFromSuperview()
        }
    }

    private func veilBody(_ reading: AndroidStageReading) -> UIView? {
        switch reading {
        case .streaming:
            nil
        case let .loading(caption):
            PhoneDevicePanelChrome.veil([
                phoneAndroidPendingSpinner(), PhoneDevicePanelChrome.caption(caption),
            ])
        case let .stalled(caption, retryTitle):
            // A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar
            // is pushed, the server is up, the encoder never started — so the stage offers the retry
            // rather than making someone go back to the list and pick the same row again.
            PhoneDevicePanelChrome.veil([
                PhoneDevicePanelChrome.caption(caption),
                PhonePanelPlateButton(title: retryTitle) { [weak self] in self?.model.retry() },
            ])
        }
    }
}
#endif
