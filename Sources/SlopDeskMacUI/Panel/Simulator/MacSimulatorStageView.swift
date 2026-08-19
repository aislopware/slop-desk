// MacSimulatorStageView — the whole streaming surface in AppKit: what device this is, the device
// itself, what you can do to it, and what it is saying (docs/56 stage D, increment 52a).
//
// THREE BANDS, top to bottom: the top bar, the device, its output. The order is not decorative — it is
// what makes a caption a caption and a drawer a drawer. The top bar names the thing the other two are
// about and carries the verbs that act on it, so it goes above them; the console is what the device
// just said, so it goes below the device rather than beside it, and the tap-watch-read loop stays one
// column.
//
// ONE SURFACE — the panel SINKS (ONE ISLAND, law 1). All three bands paint `Surface.field`, the same
// cream the navigator, the moat and the Files panel stand on, and the bands are told apart by the
// hairlines between them. This reverses the MERIDIAN L5 "two surfaces, depth by light" split that stood
// here until 2026-08-08, where the top bar was housing on `ground` and the device and console were
// content on the lit `face`. Two things retired it. The tones it named are the SYSTEM's aux backdrop
// and window ground, not this app's ground, so under ONE ISLAND they sampled a third, unrelated grey
// next to the cream. And the argument for lighting the stage no longer holds: the lit, live thing here
// is the DEVICE, which arrives already drawn as an object, so lighting the band behind it only competed
// with it.
//
// THE BODY OR A BARE RECT. With chrome loaded the stream is seated in the real device, side buttons and
// all. Without it — still loading, or a model the server cannot describe — it falls back to the plain
// rectangle, because a working screen with no bezel is a working screen, and refusing to draw until the
// artwork arrives would make a slow fetch look like a dead stream.
//
// THE TOOLBAR is the buttons the BODY cannot offer. Power, volume and the action button are physical and
// live on the bezel where the eye already expects them; Home and the app switcher are gestures with no
// hardware to click, and rotate, capture, the demo status bar, the console and the simulated position
// are host-side settings. Splitting them that way is why the toolbar is a strip rather than a palette.
//
// ## What this half spells that the phone's `.task`, `.overlay` and `.id` spelled for it
//
// ⚠️ FOUR OBSERVATIONS, EACH RE-ARMING ITSELF. `withObservationTracking` fires ONCE, so every follower
// here re-registers from inside its own `onChange` — the idiom `MacCodePanelSurfaces` established and
// the single most common way an AppKit port of an `@Observable` model goes quiet after one update. They
// are split by what they REBUILD rather than by what they read: a plate latching must not rebuild the
// header, and a device leaving the list must not tear down the console.
//
// ⚠️ THE STAGE IS KEYED ON THE UDID, which is the phone's `.id(model.selection)` and load-bearing for
// the same reason: a second device's frames must never reach a decoder configured with the first one's
// parameter sets. Switching devices BUILDS A NEW SCREEN VIEW. What is deliberately NOT rebuilt is the
// header or the toolbar — those are labels and plates, and rebuilding them would drop the popover a
// click had just opened.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacSimulatorStageView: NSView {
    private let model: SimulatorSidebarModel

    // The three bands. Hosts rather than the content itself, so a band can be emptied and refilled
    // without the column's constraints being rebuilt around it.
    private let headerHost = NSView()
    private let stageHost = NSView()
    private let consoleHost = NSView()
    private var consoleHeight: NSLayoutConstraint?

    // MARK: The toolbar's plates, kept because they LATCH

    private let rotateLeft = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.rotateLeft.symbolName,
    )
    private let rotateRight = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.rotateRight.symbolName,
    )
    private let home = MacPlateIconButton(symbolName: SimulatorPresentation.Toolbar.home.symbolName)
    private let appSwitcher = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.appSwitcher.symbolName,
    )
    private let screenshot = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.screenshot.symbolName,
    )
    private let statusBar = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.statusBar(isOverridden: false).symbolName,
    )
    private let location = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.location(isPinned: false).symbolName,
    )
    private let console = MacPlateIconButton(
        symbolName: SimulatorPresentation.Toolbar.console(isOpen: false).symbolName,
    )
    private let sending = MacSimulatorSpinner()
    private var toolbar = NSStackView()

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
    private var veilView: NSView?
    private let veilLoop = MacSimulatorLoop()

    private var consoleView: MacSimulatorConsoleView?
    /// Held so a second click on the plate reaches the same popover rather than stacking a new one over
    /// the transient close.
    private var locationPopover: MacSimulatorLocationPopover?

    private var isTargeted = false
    private let halo = MacSimulatorDropHalo()

    init(model: SimulatorSidebarModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        buildToolbar()
        buildBands()
        buildHalo()

        // The whole surface takes the drop, not just the stage: a build dragged at the console or the
        // top bar is the same intent, and a target that is a sub-rectangle of the obvious one is a
        // target people miss.
        registerForDraggedTypes([.fileURL])

        followHeader()
        followDevice()
        followStageState()
        followControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
            halo.repaint()
        }
    }

    // MARK: - The column

    private func buildBands() {
        for host in [headerHost, stageHost, consoleHost] {
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
            stageHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            consoleHost.topAnchor.constraint(equalTo: stageHost.bottomAnchor),
            consoleHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    // MARK: - Identity

    /// The band that names the device, rebuilt when any fact in it moves.
    ///
    /// ABSENT while the selection has been made but the device list has not caught up — the header's
    /// whole job is to state facts about a known device, and a header of placeholders would be the panel
    /// captioning a device it cannot name. A device can also leave the list UNDER the panel (someone
    /// shuts it down from Xcode), which is the same case arriving from the other direction.
    private func followHeader() {
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
                MainActor.assumeIsolated { self?.followHeader() }
            }
        }
        // The mounted stage learns of the turn HERE rather than through a fifth observation: the header
        // prints the orientation, so it is already reading the value the bezel needs.
        applyOrientation?(orientation)

        for view in headerHost.subviews { view.removeFromSuperview() }
        guard let device else { return }
        let band = MacSimulatorDeviceHeader(
            device: device, resolution: resolution, orientation: orientation, pinnedLocation: pinned,
            actions: toolbar,
            // ONE transaction, matching the way in: the drill's transitions are declared on the surface
            // that owns both depths, and this write is what opens a beat for them.
            onBack: { [model] in model.select(nil) },
        )
        headerHost.addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            band.topAnchor.constraint(equalTo: headerHost.topAnchor),
            band.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
        ])
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
        var udid: String?
        var bundle: SimulatorChromeBundle?
        withObservationTracking {
            udid = self.model.selection
            bundle = self.model.chrome
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followDevice() }
            }
        }
        let art = bundle.flatMap { MacSimulatorChrome.art(for: $0) }
        let wantsBody = art != nil
        guard udid != mountedDevice || wantsBody != mountedBody else { return }
        mountedDevice = udid
        mountedBody = wantsBody

        for view in stageHost.subviews where view !== veilView { view.removeFromSuperview() }
        applyOrientation = nil
        guard udid != nil else { return }

        let orientation = model.orientation
        let send: (SimulatorInputEnvelope) -> Void = { [model] in model.send($0) }
        let observed: (CGSize) -> Void = { [model] in model.observed(resolution: $0) }
        let inset: CGFloat
        let device: NSView
        if let art {
            let bezel = MacSimulatorBezelView(
                art: art, frames: model.frames, orientation: orientation,
                send: send, onContentSize: observed,
            )
            applyOrientation = { [weak bezel] in bezel?.orientation = $0 }
            device = bezel
            // The body's own margin. A bezel drawn to the band's edge reads as a screenshot of a device
            // rather than as a device standing on the panel.
            inset = Slate.Metric.space3
        } else {
            let bare = MacSimulatorBareScreen(
                frames: model.frames, orientation: orientation,
                send: send, onContentSize: observed,
            )
            applyOrientation = { [weak bare] in bare?.orientation = $0 }
            device = bare
            // NO margin without a body: the bare rect is the picture itself, and insetting it would be
            // a frame drawn around a stream to stand in for the bezel that failed to load.
            inset = 0
        }
        stageHost.addSubview(device, positioned: .below, relativeTo: veilView)
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
    private func followStageState() {
        // All three are READ for the tracking edge and none is kept: ``refreshVeil`` asks the model for
        // the current values, so a copy taken here would be one the cancelled sleep could return to
        // stale.
        withObservationTracking {
            _ = self.model.isAwaitingStream
            _ = self.model.hasVideo
            _ = self.model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followStageState() }
            }
        }
        // Keyed on the FLAG, which gives the delay `.task(id:)`'s cancellation for free: a wait for a
        // stream that arrived in time is cancelled before its veil is ever written.
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
        // followers and from the end of every delayed sleep, so building first would restart the
        // spinner several times a second for a veil that never changed.
        guard veilState != state else { return }
        veilState = state

        let wanted: NSView?
        switch state {
        case .live:
            wanted = nil
        case let .starting(caption):
            wanted = MacSimulatorVeil(caption: caption, spinner: true, action: nil)
        case let .stalled(caption):
            // A stalled stream is the one failure here that a second attempt genuinely fixes — the
            // socket is fine, the encoder never started — so the stage offers the retry rather than
            // making someone go back to the list and pick the same row again. The same plate the code
            // panel's empty states wear, so the panel has ONE wide button and not two.
            let retry = MacPanelPlateButton(title: SimulatorPresentation.retryTitle) { [model] in
                model.retry()
            }
            wanted = MacSimulatorVeil(caption: caption, spinner: false, action: retry)
        }

        let outgoing = veilView
        veilView = wanted
        if let wanted {
            wanted.alphaValue = 0
            stageHost.addSubview(wanted)
            NSLayoutConstraint.activate([
                wanted.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
                wanted.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
                wanted.topAnchor.constraint(equalTo: stageHost.topAnchor),
                wanted.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            ])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            wanted?.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        } completionHandler: {
            outgoing?.removeFromSuperview()
        }
    }

    private var veilState = SimulatorStageState.live

    // MARK: - The toolbar

    /// Three trays and a trailing pair: turn it, drive it, capture it — then look at it. Ten loose
    /// plates in a row read as texture rather than as verbs, so each job takes a tray and the rail
    /// becomes four objects instead of twelve.
    ///
    /// The inspect pair stays OFF the trays on purpose. Both are latching — a pinned position and an
    /// open console outlive the click — and a latched plate is drawn as a lit key, which reads as lit
    /// only against the panel's own tone. Sitting them on a tray would put a lit key inside a lit tray
    /// and cost exactly the signal they exist to carry.
    private func buildToolbar() {
        wire(rotateLeft, SimulatorPresentation.Toolbar.rotateLeft) { [model] in
            Task { await model.rotate(.left) }
        }
        wire(rotateRight, SimulatorPresentation.Toolbar.rotateRight) { [model] in
            Task { await model.rotate(.right) }
        }
        wire(home, SimulatorPresentation.Toolbar.home) { [model] in model.send(.button("home")) }
        wire(appSwitcher, SimulatorPresentation.Toolbar.appSwitcher) { [model] in
            model.send(.button("app-switcher"))
        }
        wire(screenshot, SimulatorPresentation.Toolbar.screenshot) { [model] in
            Task { await model.copyScreenshot() }
        }
        wire(statusBar, SimulatorPresentation.Toolbar.statusBar(isOverridden: false)) { [model] in
            Task { await model.toggleStatusBarOverride() }
        }
        wire(location, SimulatorPresentation.Toolbar.location(isPinned: false)) { [weak self] in
            self?.openLocation()
        }
        wire(console, SimulatorPresentation.Toolbar.console(isOpen: false)) { [model] in
            model.toggleConsole()
        }

        // Its arrival shifts the two plates beside it, so it fades in rather than appearing — an install
        // is the one verb here with no visible target, and the rail moving is the only thing that says
        // the drop was taken.
        sending.isHidden = true

        let trays = NSStackView(views: [
            MacSimulatorPlateTray([rotateLeft, rotateRight]),
            MacSimulatorPlateTray([home, appSwitcher]),
            MacSimulatorPlateTray([screenshot, statusBar]),
        ])
        trays.orientation = .horizontal
        trays.alignment = .centerY
        trays.spacing = Slate.Metric.space2

        let inspect = NSStackView(views: [sending, location, console])
        inspect.orientation = .horizontal
        inspect.alignment = .centerY
        inspect.spacing = Slate.Metric.space2

        toolbar = NSStackView(views: [trays, inspect])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        // The gap the vanished `Spacer` carried: at the trays' own spacing the two loose plates read as
        // a fourth tray with its fill forgotten.
        toolbar.spacing = Slate.Metric.space3
        toolbar.translatesAutoresizingMaskIntoConstraints = false
    }

    private func wire(
        _ plate: MacPlateIconButton, _ reading: SimulatorPlateReading, action: @escaping () -> Void,
    ) {
        plate.toolTip = reading.help
        plate.onClick = action
    }

    /// The latches, and the one plate whose GLYPH does not change with them.
    ///
    /// Only the tooltips and the lit state move here — a plate rebuilt to change its own latch would
    /// take the pointer's hover state and any popover anchored to it with it.
    private func followControls() {
        var isOverridden = false
        var pinned: SimulatorCoordinate?
        var isSending = false
        var isConsoleOpen = false
        withObservationTracking {
            isOverridden = self.model.isStatusBarOverridden
            pinned = self.model.pinnedLocation
            isSending = self.model.isSendingFile
            isConsoleOpen = self.model.isConsoleOpen
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followControls() }
            }
        }
        statusBar.active = isOverridden
        statusBar.toolTip = SimulatorPresentation.Toolbar.statusBar(isOverridden: isOverridden).help
        location.active = pinned != nil
        location.toolTip = SimulatorPresentation.Toolbar.location(isPinned: pinned != nil).help
        console.active = isConsoleOpen
        console.toolTip = SimulatorPresentation.Toolbar.console(isOpen: isConsoleOpen).help

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            sending.isHidden = !isSending
        }
        setConsole(open: isConsoleOpen)
    }

    private func openLocation() {
        let popover = MacSimulatorLocationPopover(pinned: model.pinnedLocation) { [model] coordinate in
            Task { await model.pin(coordinate) }
        }
        locationPopover = popover
        popover.show(from: location)
    }

    // MARK: - Output

    /// A fixed band under the device rather than a split the user drags. The device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting; a drawer
    /// that always returns the same amount of screen is a drawer nobody has to re-tune after every use.
    ///
    /// The view is BUILT on open and dropped on close, which is not just tidiness: the console holds its
    /// own observation of `logLines`, and a closed drawer that kept observing would re-attribute a
    /// 600-line burst to a view nobody can see.
    private func setConsole(open: Bool) {
        guard open != (consoleView != nil) else { return }
        if open {
            let drawer = MacSimulatorConsoleView(model: model)
            consoleView = drawer
            consoleHost.addSubview(drawer)
            NSLayoutConstraint.activate([
                drawer.leadingAnchor.constraint(equalTo: consoleHost.leadingAnchor),
                drawer.trailingAnchor.constraint(equalTo: consoleHost.trailingAnchor),
                drawer.topAnchor.constraint(equalTo: consoleHost.topAnchor),
                drawer.heightAnchor.constraint(equalToConstant: Slate.Metric.heightDrawer),
            ])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.standard.duration
            context.timingFunction = Slate.Motion.standard.timingFunction
            consoleHeight?.animator().constant = open ? Slate.Metric.heightDrawer : 0
        } completionHandler: { [weak self] in
            guard !open else { return }
            self?.consoleView?.removeFromSuperview()
            self?.consoleView = nil
        }
    }

    // MARK: - Drop to install

    // THE SERVER ROUTES A DROPPED FILE BY EXTENSION — an `.app`/`.ipa` is installed, an image or video
    // lands in Photos — so this side deliberately accepts any file and lets the server classify it.
    // Getting that taxonomy wrong locally would reject the one build someone wanted.

    private func buildHalo() {
        halo.translatesAutoresizingMaskIntoConstraints = false
        halo.isHidden = true
        addSubview(halo)
        NSLayoutConstraint.activate([
            halo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space1),
            halo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space1),
            halo.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            halo.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    /// `.copy` only for a device that is actually selected: a drop with no device to install onto has
    /// nowhere to go, and the cursor should say so before the file is let go of.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard model.selection != nil, url(from: sender) != nil else { return [] }
        setTargeted(true)
        return .copy
    }

    override func draggingExited(_: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_: NSDraggingInfo) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard model.selection != nil, let url = url(from: sender) else { return false }
        Task { @MainActor in await install(url) }
        return true
    }

    /// Takes the FIRST file of a multi-file drop. The server's route is one file per request and the
    /// install it triggers is not instant, so fanning a folder-full of builds at a device would queue
    /// installs nobody asked for.
    private func url(from sender: NSDraggingInfo) -> URL? {
        // `NSURL.self`, not `URL.self`: `readObjects(forClasses:)` takes `NSPasteboardReading`
        // conformers, and the value type does not conform. The API is the reason, not a preference.
        let found = sender.draggingPasteboard.readObjects(
            // swiftlint:disable:next legacy_objc_type
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true],
        )
        return (found?.first as? URL).flatMap { $0.isFileURL ? $0 : nil }
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            halo.isHidden = !targeted
        }
    }
}

/// The drop border. Its own view so it can sit over every band at once, and TRANSPARENT to the pointer —
/// a halo that swallowed clicks would put an invisible wall over the device for as long as it was up.
@MainActor
final class MacSimulatorDropHalo: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusPanel
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    func repaint() { layer?.borderColor = Slate.Native.accent.cgColor }
}
