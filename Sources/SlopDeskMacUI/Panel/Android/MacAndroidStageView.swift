// MacAndroidStageView — the whole mirroring surface, in AppKit (docs/56 stage D, increment 52b):
// what device this is, the device itself, what you can do to it, and what it is saying.
//
// The Mac's half of ``PhoneAndroidStageView``. The veil's fold, both toolbar trays, the verb→model table
// and every word are ``AndroidPresentation``'s and shared with the phone; what is here is the three
// bands, the mount and the two latches AppKit has to hold itself.
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
// ⚠️ THE SCREEN VIEW IS NOT A REWRITE. ``AndroidScreenNSView`` was already a plain `NSView` and it
// MOVED, verbatim, into `SlopDeskDevicePanels` in this same increment — the ledger's kind 2. This
// surface mounts it directly, which is exactly what deleted the `NSViewRepresentable` that used to
// stand between them.
//
// NO DROP TARGET (yet). The simulator stage installs a dropped `.app` because its server routes files
// by extension. The equivalent here is `adb install`, which is a different verb with a different
// failure mode (a signature mismatch, a downgrade, an ABI the device cannot run) and deserves its own
// reporting rather than being smuggled in as a drop.

import AppKit
import SFSafeSymbols
import SlopDeskClientCore // `ObservationFollow` — this stage re-follows, so it needs the replacing arm
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacAndroidStageView: NSView {
    private let model: AndroidSidebarModel

    /// The stage's own three-band frame. The header and the console come and go; the device's bed does
    /// not, so it is a stored view and the other two are swapped inside slots around it.
    private let headerSlot = NSView()
    private let bed = MacAndroidStageBed()
    private let consoleSlot = NSView()
    private var consoleHeight: NSLayoutConstraint?

    /// The mounted mirror, rebuilt per DEVICE — a second stream's frames must never be fed into a
    /// layer configured for the first one's parameter sets.
    private var screen: AndroidScreenNSView?
    private var mountedKey: String?

    /// The veil's own state, which is the model's loading state DELAYED
    /// (``AndroidPresentation/veilDelay``), and the loop that delays it.
    private var showsLoading = false
    private let veilLoop = MacDevicePanelLoop()
    /// The live arm, held because ``follow()`` has two entry points and the second must DISPLACE the
    /// first rather than add to it. Nothing else reads it.
    private var stageFollow: ObservationFollow?
    private var veil: NSView?
    private var reading: AndroidStageReading = .streaming

    /// The DEVICE's own backlight, as last set from here. Local because `scrcpy` has no read side for
    /// it: this is what the next press toggles, not a claim about the device.
    private var isDisplayOff = false
    private var plates: [AndroidStageAction: MacPlateIconButton] = [:]

    /// What the header was last built from, so a poll round that changed nothing rebuilds nothing.
    private var headerSignature: String?

    init(model: AndroidSidebarModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The three bands and the drawer's height are ``DeviceStageLayout``'s — the twenty lines that
        // used to stand here were character-identical to the phone stage's, loop variable aside.
        consoleHeight = DeviceStageLayout.stackBands(
            header: headerSlot, bed: bed, drawer: consoleSlot, in: self,
        )
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The mirror is going away — a device switch, or the panel closing. The contacts are forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone.
    ///
    /// ⚠️ THIS MUST NOT `stop()` THE FOLLOW, and the phone's same-named method must. They are not the
    /// same method: the phone's is teardown only, while this one is ALSO the mid-flight screen swap —
    /// ``mountScreen(for:videoSize:)`` calls it whenever the device key changes, which happens from
    /// inside `apply`. Ending the arm here would leave the stage permanently dead after the first
    /// device switch. The panel-closing case is covered by the view going away, which is what makes
    /// ``ObservationFollow``'s weak owner the whole teardown story here.
    func unmount() {
        veilLoop.cancel()
        screen?.abandonGestures()
        screen?.send = nil
    }

    // MARK: Following the model

    /// The one observation. ⚠️ Everything this surface draws is read INSIDE the tracked block, and the
    /// callback re-arms — `withObservationTracking` fires once per registration, so a read left
    /// outside is a band that stops updating for one reason only, which is the failure mode that
    /// survives every test.
    ///
    /// ⚠️ THIS IS CALLED TWICE, which is why it goes through ``ObservationFollow/arm(_:replacing:read:apply:)``
    /// and stores its handle. ``waitOutVeil()`` re-follows to push a `showsLoading` that the tracked
    /// block cannot see (it is this view's own state, not the model's), and under the hand-written
    /// form that second call ARMED A SECOND CHAIN while the first stayed live: every veil timeout left
    /// one more permanent arm, so a model change ran `mountScreen`/`rebuildHeader`/`setConsole` once
    /// per timeout the stage had ever survived. `replacing:` ends the previous arm, which is what the
    /// generation counter did at the sites that kept one — this file never had it.
    private func follow() {
        stageFollow = ObservationFollow.arm(self, replacing: stageFollow) { view in
            (
                device: view.model.selectedDevice,
                selection: view.model.selection,
                awaiting: view.model.isAwaitingStream,
                hasVideo: view.model.hasVideo,
                size: view.model.streamSize,
                consoleOpen: view.model.isConsoleOpen,
            )
        } apply: { view, reading in
            view.mountScreen(for: reading.selection, videoSize: reading.size)
            view.rebuildHeader(reading.device)
            view.setConsole(open: reading.consoleOpen)
            view.armVeil(selection: reading.selection, awaiting: reading.awaiting)
            view.applyReading(AndroidPresentation.stage(
                showsLoading: view.showsLoading,
                hasSelection: reading.selection != nil,
                isAwaitingStream: reading.awaiting,
                hasVideo: reading.hasVideo,
                deviceIsRunning: reading.device?.isRunning,
            ))
        }
    }

    // MARK: The device

    private func mountScreen(for key: String?, videoSize: CGSize?) {
        guard key != mountedKey else {
            screen?.videoSize = videoSize ?? .zero
            return
        }
        unmount()
        screen?.removeFromSuperview()
        screen = nil
        mountedKey = key
        guard key != nil else { return }

        let view = AndroidScreenNSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.send = { [model] message in model.send(message) }
        view.videoSize = videoSize ?? .zero
        model.frames.attach(view)
        bed.addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: bed.topAnchor, constant: Slate.Metric.space3),
            view.bottomAnchor.constraint(equalTo: bed.bottomAnchor, constant: -Slate.Metric.space3),
            view.leadingAnchor.constraint(equalTo: bed.leadingAnchor, constant: Slate.Metric.space3),
            view.trailingAnchor.constraint(
                equalTo: bed.trailingAnchor, constant: -Slate.Metric.space3,
            ),
        ])
        screen = view
        // The keyboard follows the mirror: a device just mounted is the thing a keystroke means, and
        // AppKit gives first responder to nobody unless it is asked.
        window?.makeFirstResponder(view)
    }

    // MARK: The identity band

    /// Rebuilt only when what it DRAWS changes. A device's facts arrive with the poll, so keying on
    /// the device's key alone would leave a header printing a resolution the list has since corrected.
    private func rebuildHeader(_ device: AndroidDevice?) {
        let signature = device.map { device in
            ([device.key, device.name, device.versionLabel ?? ""]
                + AndroidPresentation.facts(for: device).map { "\($0.label)=\($0.text)" })
                .joined(separator: "\u{1F}")
        }
        guard signature != headerSignature else { return }
        headerSignature = signature
        for view in headerSlot.subviews { view.removeFromSuperview() }
        plates.removeAll()
        guard let device else { return }

        let header = MacAndroidDeviceHeader(device: device, actions: toolbar) { [model] in
            model.select(nil)
        }
        headerSlot.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerSlot.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerSlot.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerSlot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerSlot.trailingAnchor),
        ])
    }

    // MARK: The toolbar

    /// Two trays: navigate it, then act on it. Loose plates in a row read as texture rather than as
    /// verbs, so each job takes a tray and the rail becomes three objects instead of eight.
    ///
    /// The console plate stays OFF the trays on purpose: it LATCHES, and a latched plate is drawn as a
    /// lit key, which reads as lit only against the panel's own tone. Sitting it on a tray would put a
    /// lit key inside a lit tray and cost exactly the signal it exists to carry.
    private var toolbar: NSView {
        let row = NSStackView(views: [
            MacDevicePanelPlateTray(AndroidPresentation.navigationTray.map(plate)),
            MacDevicePanelPlateTray(AndroidPresentation.actionTray.map(plate)),
            plate(AndroidPresentation.consoleVerb),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space3
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// One verb as a plate. The LATCH is the view's — `scrcpy` has no read side for the backlight and
    /// the drawer's own flag is the model's — and everything else about the control (its glyph, its
    /// sentence, what it does to the device) comes from below.
    private func plate(_ verb: AndroidStageVerb) -> MacPlateIconButton {
        let latched = isLatched(verb.action)
        let button = MacPlateIconButton(symbolName: verb.symbol(latched: latched).rawValue)
        button.active = latched
        button.toolTip = verb.help(latched: latched)
        button.setAccessibilityLabel(verb.help(latched: latched))
        button.onClick = { [weak self] in self?.press(verb) }
        plates[verb.action] = button
        return button
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
        if verb.action == .displayPower { isDisplayOff.toggle() }
        AndroidPresentation.run(verb.action, on: model, isDisplayOff: isDisplayOff)
        redraw(verb)
    }

    /// A latching plate redraws itself, because its glyph and its sentence both belong to the latch.
    /// The console's plate is redrawn from ``follow()`` as well, since the drawer can be closed from
    /// its own head — the model is the truth for that one, and the button is only its face.
    private func redraw(_ verb: AndroidStageVerb) {
        guard let button = plates[verb.action] else { return }
        let latched = isLatched(verb.action)
        button.symbolName = verb.symbol(latched: latched).rawValue
        button.active = latched
        button.toolTip = verb.help(latched: latched)
    }

    // MARK: The output drawer

    /// A FIXED band under the device rather than a split the user drags: the device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting.
    private func setConsole(open: Bool) {
        redraw(AndroidPresentation.consoleVerb)
        let isOpen = consoleSlot.subviews.isEmpty == false
        guard open != isOpen else { return }
        if open {
            let console = MacAndroidConsoleView(model: model)
            consoleSlot.addSubview(console)
            NSLayoutConstraint.activate([
                console.topAnchor.constraint(equalTo: consoleSlot.topAnchor),
                console.bottomAnchor.constraint(equalTo: consoleSlot.bottomAnchor),
                console.leadingAnchor.constraint(equalTo: consoleSlot.leadingAnchor),
                console.trailingAnchor.constraint(equalTo: consoleSlot.trailingAnchor),
            ])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.standard.duration
            context.timingFunction = Slate.Motion.standard.timingFunction
            context.allowsImplicitAnimation = true
            consoleHeight?.animator().constant = open ? Slate.Metric.heightDrawer : 0
            layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            // `runAnimationGroup`'s completion is `@Sendable`; AppKit runs it on the main thread
            // without annotating it as such.
            MainActor.assumeIsolated {
                guard let self, !open else { return }
                for view in self.consoleSlot.subviews { view.removeFromSuperview() }
            }
        }
    }

    // MARK: The stage's other two states

    /// The veil's delay, as a keyed task: start it when the wait starts, leave it strictly alone while
    /// the same wait holds, and cancel it the moment the wait ends — which is what makes the veil for
    /// a stream that arrived in time never appear at all.
    private func armVeil(selection: String?, awaiting: Bool) {
        guard awaiting else {
            veilLoop.cancel()
            showsLoading = false
            return
        }
        veilLoop.keyed(on: "veil/\(selection ?? "")") { [weak self] in await self?.waitOutVeil() }
    }

    /// Late on the way up, and nothing at all if the wait ended first — the loop's cancellation is
    /// what makes that second half true, so this only has to check that the world did not move under
    /// the sleep. The wait is ``DeviceVeilWait``'s, shared with the phone's stage and the simulator's.
    private func waitOutVeil() async {
        guard await DeviceVeilWait.state(isAwaiting: true, after: AndroidPresentation.veilDelay) == true,
              model.isAwaitingStream else { return }
        showsLoading = true
        follow()
    }

    /// A stage with no picture on it says which of the two reasons that is. Covering the whole DEVICE
    /// BED rather than the surface is the point twice over: the ambiguous object is the empty
    /// rectangle, and stopping at the header keeps the way out reachable while the veil is up
    /// (user-directed 2026-08-04 — a load with no end and no exit was the reported bug).
    private func applyReading(_ next: AndroidStageReading) {
        guard next != reading || veil == nil else { return }
        reading = next
        veil?.removeFromSuperview()
        veil = nil
        let built: NSView? =
            switch next {
            case .streaming:
                nil
            case let .loading(caption):
                MacDevicePanelVeil(caption: caption, spinner: true, action: nil)
            case let .stalled(caption, retry):
                // A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar
                // is pushed, the server is up, the encoder never started — so the stage offers the retry
                // rather than making someone go back to the list and pick the same row again.
                MacDevicePanelVeil(
                    caption: caption, spinner: false,
                    action: MacPanelPlateButton(title: retry) { [model] in model.retry() },
                )
            }
        guard let built else { return }
        bed.addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: bed.topAnchor),
            built.bottomAnchor.constraint(equalTo: bed.bottomAnchor),
            built.leadingAnchor.constraint(equalTo: bed.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: bed.trailingAnchor),
        ])
        veil = built
    }

    // THIS PANEL DRAWS NO BANNER. Every report leaves through the app's notification card; the
    // announcement lives on the surface that outlives both the stage and the list. What stays here is
    // the STATE, which a notification cannot carry: a mirror with no video is drawn on the stage
    // itself, where the ambiguous empty rectangle is.
}

/// The device's bed. Its own class so its fill can follow the appearance — a `CALayer` holds a FLAT
/// `CGColor`, so a dynamic `NSColor` resolved once at build time is the light theme's cream forever.
@MainActor
private final class MacAndroidStageBed: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor
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
