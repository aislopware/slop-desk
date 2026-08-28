// PhoneSimulatorStageView — the whole streaming surface: what device this is, the device itself, what
// you can do to it, and what it is saying.
//
// FOUR BANDS, top to bottom: the caption, the rail, the device, its output. The order is not
// decorative — it is what makes a caption a caption and a drawer a drawer. The caption names the thing
// the others are about, so it goes above them; the console is what the device just said, so it goes
// below the device rather than beside it, and the tap-watch-read loop stays one column.
//
// ⚠️ FOUR AND NOT THREE, which is the one place this half parts from `MacSimulatorStageView`. There the
// verbs ride the header band, because that band's trailing half was empty at every panel size — a
// ~700pt column with a ~180pt device name in it. A phone panel is 390pt, and the same ten plates plus
// their spacings are ~280 of it, which would leave sixty points for the name the band exists to print.
// So the rail takes a strip of its own, and the strip SCROLLS horizontally rather than truncating: the
// original objection to a cramped rail was that "a clipped rail puts a verb somewhere the pointer
// cannot reach", and a scrolling strip is the answer to that objection rather than a violation of it.
// The stage below is still nothing but the device.
//
// ONE SURFACE — the panel SINKS (ONE ISLAND, law 1). All four bands paint `Surface.field`, the same
// cream the navigator and the moat stand on, and they are told apart by the hairlines between them.
//
// THE BODY OR A BARE RECT. With chrome loaded the stream is seated in the real device, side buttons and
// all. Without it — still loading, or a model the server cannot describe — it falls back to the plain
// rectangle, because a working screen with no bezel is a working screen, and refusing to draw until the
// artwork arrives would make a slow fetch look like a dead stream.
//
// THE RAIL is the buttons the BODY cannot offer. Power, volume and the action button are physical and
// live on the bezel where the eye already expects them; Home and the app switcher are gestures with no
// hardware to press, and rotate, capture, the demo status bar, the keyboard, the console and the
// simulated position are host-side settings. Splitting them that way is why the rail is a strip rather
// than a palette.
//
// DROP TO INSTALL. The server routes a dropped file by extension — an `.app`/`.ipa` is installed, an
// image or video lands in Photos — so this side deliberately accepts any file and lets the server
// classify it. Getting that taxonomy wrong locally would reject the one build someone wanted. It is
// kept on the phone for iPadOS, where a drag from Files onto a mirrored device is an ordinary thing to
// do; on an iPhone the interaction simply never fires.
//
// ## What this half spells that the deleted `.task`, `.overlay` and `.id` spelled for it
//
// ⚠️ FOUR OBSERVATIONS, EACH RE-ARMING ITSELF, EACH WITH ITS OWN GENERATION. `withObservationTracking`
// fires ONCE, so every follower re-registers from inside its own `onChange`; and `[weak self]` stops a
// chain when the view dies without SUPERSEDING a live arm, so a second call to a follower would leave
// two chains multiplying on the same key path. They are split by what they REBUILD rather than by what
// they read: a plate latching must not rebuild the header, and a device leaving the list must not tear
// down the console.
//
// ⚠️ THE STAGE IS KEYED ON THE UDID, which is the deleted `.id(model.selection)` and load-bearing for
// the same reason: a second device's frames must never reach a decoder configured with the first one's
// parameter sets. Switching devices BUILDS A NEW SCREEN VIEW. What is deliberately NOT rebuilt is the
// header or the rail — those are labels and plates, and rebuilding them would drop the popover a tap
// had just opened.
//
// THIS PANEL DRAWS NO BANNER (user-directed 2026-08-04). Every report leaves through the app's
// notification card. What stays here is the STATE, which a notification cannot carry: a stream with no
// video is drawn on the stage itself, where the ambiguous empty rectangle is, with the retry beside it.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UniformTypeIdentifiers
import UIKit

@MainActor
final class PhoneSimulatorStageView: UIView, UIDropInteractionDelegate {
    private let model: SimulatorSidebarModel

    /// How a popover reaches the screen. A `UIView` cannot present, and walking up to find a controller
    /// would make this view's behaviour depend on where it happened to be mounted — so the surface that
    /// DOES own a controller hands the capability down. The second argument is the anchor.
    var present: ((UIViewController, UIView) -> Void)?

    // The four bands. Hosts rather than the content itself, so a band can be emptied and refilled
    // without the column's constraints being rebuilt around it.
    private let headerHost = UIView()
    private let railHost = UIScrollView()
    private let stageHost = UIView()
    private let consoleHost = UIView()
    private var consoleHeight: NSLayoutConstraint?
    private var header: PhoneSimulatorDeviceHeader?

    // MARK: The rail's plates, kept because they LATCH

    private lazy var rotateLeft = plate(SimulatorPresentation.Toolbar.rotateLeft) { [model] in
        Task { await model.rotate(.left) }
    }

    private lazy var rotateRight = plate(SimulatorPresentation.Toolbar.rotateRight) { [model] in
        Task { await model.rotate(.right) }
    }

    private lazy var home = plate(SimulatorPresentation.Toolbar.home) { [model] in
        model.send(.button("home"))
    }

    // A TOGGLE, and the tooltip says so. Measured 2026-08-04 against a booted device: the verb is the
    // swipe-up-and-hold gesture, so it opens the card stack from an app or the home screen and
    // DISMISSES it when the stack is already up. Neither this nor `swipe-to-app-switcher` is an
    // idempotent "show".
    //
    // NOTIFICATION CENTRE AND LOCK ARE GONE (user-directed 2026-08-04). Both were here because the
    // server offers the verb, which is not a reason: nobody driving an app reaches for the shade or the
    // lock screen, and both are DESTRUCTIVE to the thing you are actually doing. The server still
    // accepts `pull-down-to-notification-center` and `lock`; nothing upstream changed.
    private lazy var appSwitcher = plate(SimulatorPresentation.Toolbar.appSwitcher) { [model] in
        model.send(.button("app-switcher"))
    }

    private lazy var screenshot = plate(SimulatorPresentation.Toolbar.screenshot) { [model] in
        Task { await model.copyScreenshot() }
    }

    private lazy var statusBar = plate(
        SimulatorPresentation.Toolbar.statusBar(isOverridden: false),
    ) { [model] in
        Task { await model.toggleStatusBarOverride() }
    }

    /// PHONE-ONLY, and it belongs with the latching pair rather than on a tray: the keyboard it raises
    /// outlives the tap, which is what a lit key means here.
    ///
    /// It exists because THIS device may have no keys. The mirror has always typed — `pressesBegan`
    /// reads a `UIKey` and sends what the shared rule makes of it — and on a Mac that is the whole
    /// story, because a Mac has a keyboard. A phone without one could tap, swipe, rotate and screenshot
    /// the mirrored device and never put a character into it. See ``DeviceSoftKeyboard``.
    private lazy var keyboard: SlatePlateIconButton = {
        let key = SlatePlateIconButton(symbol: .keyboard) { DeviceSoftKeyboard.shared.toggle() }
        key.slateHelp(DeviceSoftKeyboard.plateHelp)
        return key
    }()

    private lazy var location = plate(
        SimulatorPresentation.Toolbar.location(isPinned: false),
    ) { [weak self] in
        self?.openLocation()
    }

    private lazy var console = plate(
        SimulatorPresentation.Toolbar.console(isOpen: false),
    ) { [model] in
        model.toggleConsole()
    }

    private let sending = phoneSimulatorPendingSpinner()

    // MARK: What is mounted right now

    /// The udid the stage is currently built for, which is how a re-run of the follower tells a
    /// selection CHANGE from any other write to the model.
    private var mountedDevice: String?
    /// Whether the mounted stage is the bezel or the bare rect — a chrome bundle arriving mid-stream is
    /// a remount, and it is the one remount that is not a device change.
    private var mountedBody = false
    /// Set on the mounted surface rather than remounting it: a turn is a rotation of a live view, and
    /// rebuilding the screen for one would drop the stream to re-acquire a keyframe.
    private var applyOrientation: ((SimulatorOrientation) -> Void)?

    /// The veil's own state, which is the model's loading state DELAYED — see
    /// ``SimulatorPresentation/veilDelay``.
    private var showsLoading = false
    private var veilView: UIView?
    private var veilState = SimulatorStageState.live
    private let veilLoop = PhoneSimulatorLoop()

    private var consoleView: PhoneSimulatorConsoleView?

    private var isTargeted = false
    private let halo = UIView()

    private var headerGeneration = 0
    private var deviceGeneration = 0
    private var stageGeneration = 0
    private var controlsGeneration = 0

    init(model: SimulatorSidebarModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.field

        buildBands()
        buildRail()
        buildHalo()

        // The whole surface takes the drop, not just the stage: a build dragged at the console or the
        // rail is the same intent, and a target that is a sub-rectangle of the obvious one is a target
        // people miss.
        addInteraction(UIDropInteraction(delegate: self))

        followHeader()
        followDevice()
        followStageState()
        followControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: - The column

    private func buildBands() {
        for host in [headerHost, railHost, stageHost, consoleHost] {
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        // CLOSED to zero rather than removed from the column, so the drawer has one number to animate
        // and the stage's own bottom edge never becomes a different constraint.
        let height = consoleHost.heightAnchor.constraint(equalToConstant: 0)
        consoleHeight = height
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: topAnchor),
            railHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            railHost.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            stageHost.topAnchor.constraint(equalTo: railHost.bottomAnchor),
            consoleHost.topAnchor.constraint(equalTo: stageHost.bottomAnchor),
            consoleHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    // MARK: - Identity

    /// The band that names the device, relabelled when any fact in it moves.
    ///
    /// ABSENT while the selection has been made but the device list has not caught up — the header's
    /// whole job is to state facts about a known device, and a header of placeholders would be the panel
    /// captioning a device it cannot name. A device can also leave the list UNDER the panel (someone
    /// shuts it down from Xcode), which is the same case arriving from the other direction. The RAIL
    /// goes with it: verbs that act on a device the panel cannot name are verbs with no subject.
    private func followHeader() {
        headerGeneration &+= 1
        let generation = headerGeneration
        var device: SimulatorDevice?
        var resolution: CGSize?
        var orientation = SimulatorOrientation.portrait
        var pinned: SimulatorCoordinate?
        withObservationTracking {
            device = self.selected
            resolution = self.model.resolution
            orientation = self.model.orientation
            pinned = self.model.pinnedLocation
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == headerGeneration else { return }
                    followHeader()
                }
            }
        }
        // The mounted stage learns of the turn HERE rather than through a fifth observation: the header
        // prints the orientation, so it is already reading the value the bezel needs.
        applyOrientation?(orientation)

        guard let device else {
            fade(headerHost, to: 0)
            fade(railHost, to: 0)
            header?.removeFromSuperview()
            header = nil
            return
        }
        fade(headerHost, to: 1)
        fade(railHost, to: 1)
        let reading = PhoneSimulatorDeviceHeader.Reading(
            device: device, resolution: resolution, orientation: orientation, pinnedLocation: pinned,
        )
        guard let header else {
            let band = PhoneSimulatorDeviceHeader(reading: reading) { [model] in model.select(nil) }
            self.header = band
            headerHost.addSubview(band)
            NSLayoutConstraint.activate([
                band.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
                band.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
                band.topAnchor.constraint(equalTo: headerHost.topAnchor),
                band.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
            ])
            return
        }
        // RELABELLED, not rebuilt: the band's shape never changes, only the words in it, and a remount
        // would drop each fact's own Copy interaction on every poll that ticked a state string.
        header.reading = reading
    }

    private var selected: SimulatorDevice? {
        guard let udid = model.selection else { return nil }
        return model.devices.first { $0.udid == udid }
    }

    // MARK: - The device

    /// Mount the bezel, or the bare rect, for the selected device.
    ///
    /// ⚠️ THE GUARD IS THE WHOLE FUNCTION. This follower runs on every write to `chrome` or `selection`,
    /// and a remount is a torn-down decoder — so it remounts only when the DEVICE or the BODY-vs-BARE
    /// answer actually changed. Without the guard a chrome fetch that resolves to the same bundle would
    /// drop the stream for a keyframe.
    private func followDevice() {
        deviceGeneration &+= 1
        let generation = deviceGeneration
        var udid: String?
        var bundle: SimulatorChromeBundle?
        withObservationTracking {
            udid = self.model.selection
            bundle = self.model.chrome
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == deviceGeneration else { return }
                    followDevice()
                }
            }
        }
        let art = bundle.flatMap { PhoneSimulatorChrome.art(for: $0) }
        let wantsBody = art != nil
        guard udid != mountedDevice || wantsBody != mountedBody else { return }
        mountedDevice = udid
        mountedBody = wantsBody

        for view in stageHost.subviews where view !== veilView { view.removeFromSuperview() }
        applyOrientation = nil
        // The keyboard plate gates on the stage having mounted a MIRROR at all, which is a fact this
        // function already knows — see ``DeviceSoftKeyboard``'s note on the reader that was struck.
        keyboard.isEnabled = udid != nil
        guard udid != nil else { return }

        let orientation = model.orientation
        let send: (SimulatorInputEnvelope) -> Void = { [model] in model.send($0) }
        let observed: (CGSize) -> Void = { [model] in model.observed(resolution: $0) }
        let inset: CGFloat
        let device: UIView
        if let art {
            let bezel = PhoneSimulatorBezelView(
                art: art, frames: model.frames, orientation: orientation,
                send: send, onContentSize: observed,
            )
            applyOrientation = { [weak bezel] in bezel?.orientation = $0 }
            device = bezel
            // The body's own margin. A bezel drawn to the band's edge reads as a screenshot of a device
            // rather than as a device standing on the panel.
            inset = Slate.Metric.space3
        } else {
            let bare = PhoneSimulatorBareScreen(
                frames: model.frames, orientation: orientation,
                send: send, onContentSize: observed,
            )
            applyOrientation = { [weak bare] in bare?.orientation = $0 }
            device = bare
            // NO margin without a body: the bare rect is the picture itself, and insetting it would be a
            // frame drawn around a stream to stand in for the bezel that failed to load.
            inset = 0
        }
        stageHost.insertSubview(device, at: 0)
        NSLayoutConstraint.activate([
            device.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor, constant: inset),
            device.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor, constant: -inset),
            device.topAnchor.constraint(equalTo: stageHost.topAnchor, constant: inset),
            device.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - The stage's other two states

    /// Re-decide whether a veil is up, and restart the DELAY whenever the model's own loading flag
    /// moves. ``SimulatorPresentation/stage(isSelected:showsLoading:isAwaitingStream:hasVideo:)`` owns
    /// the ordering of the three answers; this reads the four inputs and draws the one it is handed.
    ///
    /// The ORDER is the part worth naming: asked in any other sequence the stage prints "no video" for
    /// the 90 ms before the first keyframe of every single selection.
    private func followStageState() {
        stageGeneration &+= 1
        let generation = stageGeneration
        // All three are READ for the tracking edge and none is kept: ``refreshVeil`` asks the model for
        // the current values, so a copy taken here would be one the cancelled sleep could return to
        // stale.
        withObservationTracking {
            _ = self.model.isAwaitingStream
            _ = self.model.hasVideo
            _ = self.model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == stageGeneration else { return }
                    followStageState()
                }
            }
        }
        // Keyed on the FLAG, which gives the delay `.task(id:)`'s cancellation for free: a wait for a
        // stream that arrived in time is cancelled before its veil is ever written. The delay itself is
        // ``SimulatorPresentation/loadingVeil(isAwaiting:)``'s — 400 ms measured against this server's
        // 0.09 s first keyframe, which is why the panels share the RULE and not the figure.
        let isAwaiting = model.isAwaitingStream
        veilLoop.keyed(on: isAwaiting ? "awaiting" : "settled") { [weak self] in
            guard let state = await SimulatorPresentation.loadingVeil(isAwaiting: isAwaiting)
            else { return }
            self?.showsLoading = state
            self?.refreshVeil()
        }
        refreshVeil()
    }

    /// A stage with no picture on it says WHICH of the two reasons that is. Covering the stage rather
    /// than captioning it from the header is the point: the ambiguous object IS the empty rectangle, and
    /// an empty rectangle, a black screenshot and a dead stream are pixel-identical. It stops at the
    /// header, which keeps the way out reachable while it is up (user-directed 2026-08-04 — a load with
    /// no end and no exit was the reported bug).
    private func refreshVeil() {
        let state = SimulatorPresentation.stage(
            isSelected: model.selection != nil, showsLoading: showsLoading,
            isAwaitingStream: model.isAwaitingStream, hasVideo: model.hasVideo,
        )
        // The GUARD comes before the build, and the comparison is by VALUE: this is called from two
        // followers and from the end of every delayed sleep, so building first would restart the spinner
        // several times a second for a veil that never changed.
        guard veilState != state else { return }
        veilState = state

        let wanted: UIView?
        switch state {
        case .live:
            wanted = nil
        case let .starting(caption):
            wanted = PhoneDevicePanelChrome.veil([
                phoneSimulatorPendingSpinner(), PhoneDevicePanelChrome.caption(caption),
            ])
        case let .stalled(caption):
            // A stalled stream is the one failure here that a second attempt genuinely fixes — the
            // socket is fine, the encoder never started — so the stage offers the retry rather than
            // making someone go back to the list and pick the same row again. The same plate the code
            // panel's empty states wear, so the panel has ONE wide button and not two.
            let retry = PhonePanelPlateButton(title: SimulatorPresentation.retryTitle) { [model] in
                model.retry()
            }
            wanted = PhoneDevicePanelChrome.veil([
                PhoneDevicePanelChrome.caption(caption), retry,
            ])
        }

        let outgoing = veilView
        veilView = wanted
        if let wanted {
            wanted.alpha = 0
            stageHost.addSubview(wanted)
            NSLayoutConstraint.activate([
                wanted.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
                wanted.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
                wanted.topAnchor.constraint(equalTo: stageHost.topAnchor),
                wanted.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            ])
        }
        phoneSimulatorAnimate(Slate.Motion.smallFade) {
            wanted?.alpha = 1
            outgoing?.alpha = 0
        } completion: {
            outgoing?.removeFromSuperview()
        }
    }

    // MARK: - The rail

    /// Three trays and a trailing run: turn it, drive it, capture it — then look at it. Ten loose plates
    /// in a row read as texture rather than as verbs, so each job takes a tray and the rail becomes four
    /// objects instead of twelve.
    ///
    /// The inspect run stays OFF the trays on purpose. All three latch — a raised keyboard, a pinned
    /// position and an open console outlive the tap — and a latched plate is drawn as a lit key, which
    /// reads as lit only against the panel's own tone. Sitting them on a tray would put a lit key inside
    /// a lit tray and cost exactly the signal they exist to carry.
    private func buildRail() {
        // Its arrival shifts the plates beside it, so it fades in rather than appearing — an install is
        // the one verb here with no visible target, and the rail moving is the only thing that says the
        // drop was taken.
        sending.alpha = 0

        let trays = UIStackView(arrangedSubviews: [
            SlatePlateTray([rotateLeft, rotateRight]),
            SlatePlateTray([home, appSwitcher]),
            SlatePlateTray([screenshot, statusBar]),
        ])
        trays.translatesAutoresizingMaskIntoConstraints = false
        trays.axis = .horizontal
        trays.alignment = .center
        trays.spacing = Slate.Metric.space2

        let inspect = UIStackView(arrangedSubviews: [sending, keyboard, location, console])
        inspect.translatesAutoresizingMaskIntoConstraints = false
        inspect.axis = .horizontal
        inspect.alignment = .center
        inspect.spacing = Slate.Metric.space2

        let rail = UIStackView(arrangedSubviews: [trays, inspect])
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.axis = .horizontal
        rail.alignment = .center
        // The gap that separates the inspect run from the trays: at the trays' own spacing those loose
        // plates read as a fourth tray with its fill forgotten.
        rail.spacing = Slate.Metric.space3

        railHost.showsHorizontalScrollIndicator = false
        railHost.alwaysBounceHorizontal = false
        railHost.addSubview(rail)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(
                equalTo: railHost.contentLayoutGuide.leadingAnchor, constant: Slate.Metric.space2,
            ),
            rail.trailingAnchor.constraint(
                equalTo: railHost.contentLayoutGuide.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            rail.topAnchor.constraint(equalTo: railHost.contentLayoutGuide.topAnchor),
            rail.bottomAnchor.constraint(equalTo: railHost.contentLayoutGuide.bottomAnchor),
            rail.heightAnchor.constraint(equalTo: railHost.frameLayoutGuide.heightAnchor),
            // ⚠️ The MINIMUM, not an equality: the rail is as wide as it needs to be and scrolls when
            // that exceeds the panel, and it fills the panel when it does not. An equality here would
            // squeeze ten fixed-size plates into 390 points and overlap them.
            rail.widthAnchor.constraint(
                greaterThanOrEqualTo: railHost.frameLayoutGuide.widthAnchor,
                constant: -2 * Slate.Metric.space2,
            ),
        ])
    }

    /// One plate, wired to its reading. The plate's own SYMBOL is read once, from the unlatched state:
    /// only the tooltip and the lit state move afterwards, because a plate REBUILT to change its glyph
    /// would take the pointer's hover state and any popover anchored to it with it.
    private func plate(
        _ reading: SimulatorPlateReading, action: @escaping () -> Void,
    ) -> SlatePlateIconButton {
        let button = SlatePlateIconButton(symbol: reading.symbol, action: action)
        button.slateHelp(reading.help)
        return button
    }

    /// The latches, and the one plate whose glyph does not change with them.
    private func followControls() {
        controlsGeneration &+= 1
        let generation = controlsGeneration
        var isOverridden = false
        var pinned: SimulatorCoordinate?
        var isSending = false
        var isConsoleOpen = false
        var isTyping = false
        withObservationTracking {
            isOverridden = self.model.isStatusBarOverridden
            pinned = self.model.pinnedLocation
            isSending = self.model.isSendingFile
            isConsoleOpen = self.model.isConsoleOpen
            // The soft keyboard is its OWN observable — the mirror writes `isTyping` back when the
            // system's dismiss gesture takes the keyboard down, so a plate lit off the model's state
            // alone would stay lit over a keyboard that is not there.
            isTyping = DeviceSoftKeyboard.shared.isTyping
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == controlsGeneration else { return }
                    followControls()
                }
            }
        }
        statusBar.active = isOverridden
        statusBar.slateHelp(SimulatorPresentation.Toolbar.statusBar(isOverridden: isOverridden).help)
        location.active = pinned != nil
        location.slateHelp(SimulatorPresentation.Toolbar.location(isPinned: pinned != nil).help)
        console.active = isConsoleOpen
        console.slateHelp(SimulatorPresentation.Toolbar.console(isOpen: isConsoleOpen).help)
        keyboard.active = isTyping

        fade(sending, to: isSending ? 1 : 0)
        setConsole(open: isConsoleOpen)
    }

    private func openLocation() {
        let popover = PhoneSimulatorLocationPopover(pinned: model.pinnedLocation) { [model] coordinate in
            Task { await model.pin(coordinate) }
        }
        // Anchored to the plate that opened it, which is what makes it read as that plate's own detail.
        present?(popover, location)
    }

    // MARK: - Output

    /// A fixed band under the device rather than a split the user drags. The device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting; a drawer
    /// that always returns the same amount of screen is a drawer nobody has to re-tune after every use.
    ///
    /// The view is BUILT on open and DROPPED on close, which is not just tidiness: the console holds its
    /// own observation of `logLines`, and a closed drawer that kept observing would re-attribute a
    /// 600-line burst to a view nobody can see.
    private func setConsole(open: Bool) {
        guard open != (consoleView != nil) else { return }
        if open {
            let drawer = PhoneSimulatorConsoleView(model: model)
            consoleView = drawer
            consoleHost.addSubview(drawer)
            NSLayoutConstraint.activate([
                drawer.leadingAnchor.constraint(equalTo: consoleHost.leadingAnchor),
                drawer.trailingAnchor.constraint(equalTo: consoleHost.trailingAnchor),
                drawer.topAnchor.constraint(equalTo: consoleHost.topAnchor),
                drawer.heightAnchor.constraint(equalToConstant: Slate.Metric.heightDrawer),
            ])
        }
        consoleHeight?.constant = open ? Slate.Metric.heightDrawer : 0
        phoneSimulatorAnimate(Slate.Motion.standard) { [weak self] in
            self?.layoutIfNeeded()
        } completion: { [weak self] in
            guard !open else { return }
            self?.consoleView?.removeFromSuperview()
            self?.consoleView = nil
        }
    }

    // MARK: - Drop to install

    private func buildHalo() {
        halo.translatesAutoresizingMaskIntoConstraints = false
        halo.alpha = 0
        halo.layer.cornerRadius = Slate.Metric.radiusPanel
        halo.layer.cornerCurve = .continuous
        halo.layer.borderWidth = Slate.Metric.cardBorderWidth
        // A halo that swallowed touches would put an invisible wall over the device for as long as it
        // was up — the UIKit spelling of the Mac halo's `hitTest → nil`.
        halo.isUserInteractionEnabled = false
        repaintHalo()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.repaintHalo()
        }
        addSubview(halo)
        NSLayoutConstraint.activate([
            halo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space1),
            halo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space1),
            halo.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            halo.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    /// ⚠️ A `CGColor` on a layer is RESOLVED, not dynamic — it is whatever appearance was current when it
    /// was taken, so it has to be re-taken from the trait registration.
    private func repaintHalo() {
        halo.layer.borderColor = Slate.Native.accent.resolvedColor(with: traitCollection).cgColor
    }

    func dropInteraction(_: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: URL.self)
    }

    /// `.copy` only for a device that is actually selected: a drop with no device to install onto has
    /// nowhere to go, and the affordance should say so before the file is let go of.
    func dropInteraction(
        _: UIDropInteraction, sessionDidUpdate _: any UIDropSession,
    ) -> UIDropProposal {
        guard model.selection != nil else { return UIDropProposal(operation: .cancel) }
        setTargeted(true)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_: UIDropInteraction, sessionDidExit _: any UIDropSession) {
        setTargeted(false)
    }

    func dropInteraction(_: UIDropInteraction, sessionDidEnd _: any UIDropSession) {
        setTargeted(false)
    }

    /// Takes the FIRST file of a multi-file drop. The server's route is one file per request and the
    /// install it triggers is not instant, so fanning a folder-full of builds at a device would queue
    /// installs nobody asked for.
    ///
    /// `loadObjects(ofClass: URL.self)` rather than `loadFileRepresentation`: the pane drop receiver
    /// reads dropped URLs the same way, and matching the spelling already proven in this app beats a
    /// second one — a file representation would also hand over a TEMPORARY copy that is unlinked when
    /// the handler returns, where this URL is the real one and carries the sandbox extension the read
    /// below needs.
    func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
        setTargeted(false)
        guard model.selection != nil else { return }
        session.loadObjects(ofClass: URL.self) { [weak self] items in
            MainActor.assumeIsolated {
                guard let self, let url = items.first as? URL, url.isFileURL else { return }
                Task { await self.install(url) }
            }
        }
    }

    private func install(_ url: URL) async {
        // ⚠️ The URL carries a sandbox extension that has to be opened before the bytes can be read; the
        // app is sandboxed, so without this the read fails on every drop from outside it.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            model.report(SimulatorPresentation.unreadableDrop(url.lastPathComponent))
            return
        }
        await model.send(file: url, contents: contents)
    }

    /// The drop affordance is a BORDER, not a dimming veil: the point of dropping onto a live screen is
    /// watching the install land, and covering the device to say "you may drop here" hides it.
    private func setTargeted(_ targeted: Bool) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        fade(halo, to: targeted ? 1 : 0)
    }

    // MARK: - One fade

    /// Every appearance and disappearance in this file is the same beat, spelled once. `alpha` and never
    /// `isHidden`: a hidden subtree does not lay out, so a band that came back would arrive un-laid-out
    /// for one frame.
    private func fade(_ view: UIView, to alpha: CGFloat) {
        guard view.alpha != alpha else { return }
        phoneSimulatorAnimate(Slate.Motion.smallFade) { view.alpha = alpha }
    }
}
#endif
