// MacGuiLeafView — the remote-window (PATH 2) pane leaf, in AppKit: the video parallel of
// ``MacTerminalLeafView`` and the third of docs/56 batch R10's three files.
//
// It mounts the `VideoWindowFactory` seam over a `CAMetalLayer`, drives the cap-enforced activation
// lifecycle, and draws the seven pieces of chrome over the stream. The DECISIONS are all
// somewhere else and unchanged: `RemoteGUIDisplay.resolve` picks live / entry-form / cap-gated,
// `GuiPaneReadout` owns every gate and string, `GuiPaneUploads` routes a drop, and
// `PaneImmersiveCapture` owns the tap. What crossed is the drawing and the lifecycle.
//
// TWO THINGS SWIFTUI DID FOR FREE THAT THIS FILE MUST DO BY HAND, and they are the whole reason the
// AppKit half is longer than the SwiftUI one:
//
//   • THE GATES. `RemotePaneContext` was rebuilt on every render pass there, so a read-only flip
//     re-published the injector sinks by simply being re-evaluated. An AppKit canvas has no render
//     pass, so ``push()`` calls `RemoteSurfaceHosting.setPaneGates` explicitly. Miss it and a lock
//     stops reaching the host on THIS canvas and not the other — the exact divergence docs/56 stage F
//     names.
//   • THE EDGES. Four `.onChange`s (focus, injectability, the immersive wish, visibility) and one
//     `.task(id:)` become one tracked read plus remembered last-values. The activation key is the
//     same pure `GuiPaneReadout.activationKey(...)` string, so "did the key change" is still one
//     comparison and not four.
//
// EDGE-TO-EDGE, unlike the terminal leaf's inset: every point of a video pane is remote pixels, so a
// gutter here is wasted stream area rather than a reading margin. The chrome floats over it.

import AppKit
import Defaults
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The leaf

@MainActor
final class MacGuiLeafView: NSView {
    // MARK: What the leaf was handed

    private let store: WorkspaceStore
    private let paneID: PaneID
    private var live: LivePaneSession?
    private var isFocused: Bool
    /// Whether this pane is ON-SCREEN (tab active AND not zoom-hidden). Under keep-all-mounted a
    /// hidden tab's leaf is never unmounted, so this — not `viewDidMoveToWindow` — is what frees the
    /// `liveVideoCap` slot and stops the UDP/VT/Metal pipeline off-screen.
    private var isVisible: Bool

    private var model: RemoteWindowModel? { live?.remoteWindow }

    // MARK: The pixels

    /// The seam's view, or the placeholder. Whichever is mounted fills the leaf.
    private var surfaceView: NSView?
    private var surfaceHost: RemoteSurfaceHosting?
    private let placeholder = MacGuiPlaceholderView()
    /// What ``mountSurface()`` last built for, so a `follow()` pass that changed nothing about the
    /// descriptor does not tear a live decode stack down and rebuild it.
    private var mountedDescriptor: RemoteWindowDescriptor?

    // MARK: The chrome — every piece STANDING, hidden rather than absent

    private let controlBar = MacGuiPaneControlBar()
    private let collapsedChip = MacGuiCollapsedControlsChip()
    private let stallCaption = MacStreamStallCaption()
    private let statsReadout = MacGuiStatsReadout()
    private let uploadOverlay = MacFileUploadOverlay()
    private let dropHighlight = MacFileDropHighlight()
    private let readOnlyPill: MacPaneStatusPillView
    /// The ONE piece that is rebuilt: its copy is baked in at init, and it is transient by design.
    private var pasteBanner: MacPasteFeedbackBanner?
    /// The paste banner clears the control bar when the bar is expanded, so this constant moves.
    private var pasteBannerBottom: NSLayoutConstraint?

    // MARK: Per-pane view state — resets on remount, exactly like the SwiftUI `@State` it replaces

    private var showStats = false
    private var controlsExpanded = false
    private var isDropTargeted = false
    /// The tap must die with this MOUNT, while the on/off WISH lives on the model — which is what
    /// makes a detach/reattach re-engage instead of silently dropping the mode.
    private let immersiveCapture = PaneImmersiveCapture()

    // MARK: The live reads

    /// Supersedes an armed observation. An arm cannot be cancelled, so a stale callback drops itself.
    private var generation = 0
    private var isWired = false
    private var settingsTask: Task<Void, Never>?
    private var satelliteBackgroundPointer = Defaults[.satelliteBackgroundPointer]

    /// Last values of the four things the SwiftUI half gave an `.onChange` each. Optional-less: every
    /// one has a well-defined false/empty reading for a pane with no model.
    private var lastActivationKey: String?
    private var lastInjectable = false
    private var lastImmersiveWish = false

    // MARK: - Life

    init(live: LivePaneSession?, isFocused: Bool, isVisible: Bool, store: WorkspaceStore, paneID: PaneID) {
        self.live = live
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.store = store
        self.paneID = paneID
        readOnlyPill = MacPaneStatusPillView(pill: .readOnly) { store.setPaneReadOnly(paneID, false) }
        super.init(frame: .zero)
        build()
        mountSurface()
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        paint()
        registerForDraggedTypes([.fileURL])

        // THE FLOOR, added before everything else so it is at the BACK: the placeholder shows through
        // whenever no surface is mounted, and the seam's view goes in above it.
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        fillConstraints(placeholder).forEach { $0.isActive = true }

        // Pinned in z-order, bottom-up. The drop highlight sits ABOVE the chrome on purpose: it is a
        // whole-leaf border and a control bar drawn over it would break the frame it is trying to draw.
        controlBar.onCollapse = { [weak self] in self?.setControlsExpanded(false) }
        controlBar.onToggleStats = { [weak self] in self?.setShowStats(!(self?.showStats ?? false)) }
        controlBar.onToggleImmersive = { [weak self] in
            guard let self else { return }
            immersiveCapture.toggle(model: model)
        }
        collapsedChip.onExpand = { [weak self] in self?.setControlsExpanded(true) }

        for overlay in [
            controlBar,
            collapsedChip,
            stallCaption,
            statsReadout,
            uploadOverlay,
            readOnlyPill,
            dropHighlight,
        ] as [NSView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.alphaValue = 0
            overlay.isHidden = true
            addSubview(overlay)
        }
        fillConstraints(dropHighlight).forEach { $0.isActive = true }

        let pad = Slate.Metric.space2
        NSLayoutConstraint.activate([
            controlBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingAnchor.constraint(equalTo: collapsedChip.trailingAnchor, constant: pad),
            bottomAnchor.constraint(equalTo: collapsedChip.bottomAnchor, constant: pad),
            // BOTTOM-LEADING for the stall caption: bottom-trailing is the chip's corner, and the two
            // can be on screen at once (a stalled stream still has controls).
            stallCaption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            bottomAnchor.constraint(equalTo: stallCaption.bottomAnchor, constant: Slate.Metric.space3),
            statsReadout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            statsReadout.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            // TOP-CENTRE for uploads — clear of the read-only pill top-trailing and the stats readout
            // top-leading, which is the only free corner-free edge left.
            uploadOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            uploadOverlay.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            trailingAnchor.constraint(equalTo: readOnlyPill.trailingAnchor, constant: pad),
            readOnlyPill.topAnchor.constraint(equalTo: topAnchor, constant: pad),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { paint() }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Attach / detach, and the one thing that is not symmetric

    /// The AppKit spelling of `.onAppear` / `.onDisappear`, with the SAME asymmetry the terminal leaf
    /// carries and for a stricter reason.
    ///
    /// The OBSERVATION detaches with the view tree; it is idempotent and re-installable.
    ///
    /// The CAP SLOT does not, because a leaf can leave the tree without its pane going away — a split
    /// rearrange re-parents it, and detach/reattach mounts another hosting root for the SAME PaneID
    /// while this one is still coming down. Deactivating here would close the model mid-handoff and
    /// race the replacement's fresh session. Only ``teardown()`` frees the slot, and only after
    /// checking the pane is gone from the tree AND from the detached set.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, superview == nil {
            detach()
        } else if window != nil {
            attach()
        }
    }

    private func attach() {
        guard !isWired else { return }
        isWired = true
        followSettings()
        follow()
    }

    private func detach() {
        guard isWired else { return }
        isWired = false
        generation &+= 1
        settingsTask?.cancel()
        settingsTask = nil
    }

    /// The pane is closed for good.
    ///
    /// The immersive tap comes down FIRST and unconditionally: an unmounted pane that keeps swallowing
    /// the keyboard has no owner left to disengage it. ``PaneImmersiveCapture/teardown()`` is the verb
    /// that drops the tap WITHOUT clearing the model's wish, so a reattach still re-engages.
    func teardown() {
        detach()
        immersiveCapture.teardown()
        surfaceHost?.detachSurface()
        surfaceHost = nil
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        mountedDescriptor = nil
        // THE RELOCATION GUARD. Gone from the tree AND not detached is the only reading of "closed".
        guard !store.tree.contains(paneID), !store.tree.isDetached(paneID) else { return }
        store.deactivateVideo(paneID)
    }

    // MARK: - What the mounter pushes

    func setLive(_ live: LivePaneSession?) {
        guard live !== self.live else { return }
        self.live = live
        mountSurface()
        if isWired { follow() }
    }

    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        push()
        // IMMERSIVE SAFETY: focus drives a SUSPENSION, never a tear-down. Losing focus pauses
        // swallowing; regaining it resumes by itself, so the user's toggle survives a popover blip.
        immersiveCapture.setSuspended(!isFocused || model?.canInjectSystemKeys != true)
        immersiveCapture.autoEngage(model: model, isFocused: isFocused)
        if isWired { follow() }
    }

    func setVisible(_ isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
        if isWired { follow() }
    }

    // MARK: - The pixels

    /// The video seam — the production renderer if the app registered a native factory, else the
    /// placeholder. This target NEVER imports Metal or VideoToolbox: it only calls the factory.
    private func mountSurface() {
        let descriptor = model?.active
        // A REBUILD IS A TEARDOWN. `MetalLayerBackedView` owns UDP sockets, a decoder and a display
        // link, so remounting for an unchanged descriptor would reset a live stream mid-frame — the
        // identity hazard the SwiftUI half spells as "never reconstruct the hosted view across panes".
        if descriptor == mountedDescriptor, surfaceView != nil || descriptor == nil { return }
        surfaceHost?.detachSurface()
        surfaceHost = nil
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        mountedDescriptor = descriptor

        guard let descriptor else { return }
        guard let host = VideoWindowFactory.makeNative(descriptor, context: paneContext()) else { return }
        surfaceHost = host
        fillSurface(host.surfaceView)
    }

    /// The per-render context SwiftUI rebuilt on every pass. Built here at MOUNT, and its three gates
    /// re-pushed by ``push()`` afterwards — the sinks below are bound once because they are bound to
    /// the model, and it is `setPaneGates` that republishes them on a read-only flip.
    private func paneContext() -> RemotePaneContext {
        RemotePaneContext.videoLeaf(
            isActive: isFocused,
            readOnly: store.isReadOnly(for: paneID),
            // A DETACHED pane's satellite window keeps taking pointer input while not key
            // (setting-gated); a canvas pane never does.
            backgroundPointer: store.tree.isDetached(paneID) && satelliteBackgroundPointer,
            onActivate: { [weak self] in
                guard let self else { return }
                store.focusPaneTree(paneID)
            },
            onCanvasScroll: { _ in },
            // `nil` letterboxes a TILED leaf via `.fit` instead of fighting the split solver.
            onStreamNativeSize: nil,
            bindKeyInjector: { [weak model] sink in model?.keyInjector = sink },
            bindResizeInjector: { [weak model] sink in model?.resizeInjector = sink },
            bindViewportInjector: { [weak model] sink in model?.viewportInjector = sink },
            bindInputRelease: { [weak model] sink in model?.inputReleaseInjector = sink },
            bindStreamSettingsInjector: { [weak model] sink in model?.streamSettingsInjector = sink },
            bindAudioInjector: { [weak model] sink in model?.audioInjector = sink },
            bindPrivacyInjector: { [weak model] sink in model?.privacyInjector = sink },
            bindSystemKeyInjector: { [weak model] sink in model?.systemKeyInjector = sink },
            onWindowGeometry: { [weak model] cw, ch, mw, mh in
                model?.noteWindowGeometry(currentW: cw, currentH: ch, maxW: mw, maxH: mh)
            },
            onStreamCadence: { [weak model] fps in model?.noteStreamFps(fps) },
            onStreamBitrate: { [weak model] kbps in model?.noteStreamKbps(kbps) },
            onNetworkStats: { [weak model] fps, fec, unrecovered, holdMs, depth, rtt, enc, dec in
                model?.noteNetworkStats(
                    fps: fps, fecPerSec: fec, unrecoveredPerSec: unrecovered,
                    holdMs: holdMs, pacerDepth: depth,
                    rttMs: rtt, encodeMs: enc, decodeMs: dec,
                )
            },
            onStreamStall: { [weak model] stalled in model?.noteStreamStalled(stalled) },
            onSessionRejected: { [weak model] in model?.noteSessionRejected() },
        )
    }

    /// THE ONLY WAY A READ-ONLY LOCK REACHES THE HOST on this canvas. SwiftUI got this from being
    /// re-run; here it is a call, and every edge that can change one of the three gates makes it.
    private func push() {
        surfaceHost?.setPaneGates(
            isActive: isFocused,
            inputEnabled: !store.isReadOnly(for: paneID),
            backgroundPointer: store.tree.isDetached(paneID) && satelliteBackgroundPointer,
        )
    }

    /// Mount the seam's view between the placeholder and the chrome.
    ///
    /// `positioned:relativeTo:` rather than a plain `addSubview`, because the chrome was added in
    /// ``build()`` and a plain add would put the remote pixels ON TOP of the control bar — which would
    /// not merely look wrong, it would put an opaque `CAMetalLayer` over every overlay in the file.
    private func fillSurface(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: controlBar)
        surfaceView = view
        fillConstraints(view).forEach { $0.isActive = true }
        placeholder.isHidden = true
    }

    private func fillConstraints(_ view: NSView) -> [NSLayoutConstraint] {
        [
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
    }

    // MARK: - The live read

    /// ONE tracked read of everything this leaf draws, activates on, or triggers an immersive edge
    /// from — re-armed by its own `onChange`, superseded by generation.
    ///
    /// One arm rather than one per concern for the same reason the terminal leaf gives:
    /// `withObservationTracking` fires on the FIRST change to anything it read, so N arms cost N
    /// callbacks for one edit and give nothing back.
    private func follow() {
        generation &+= 1
        let generation = generation

        var display = RemoteGUIDisplay.entryForm
        var activationKey = ""
        var injectable = false
        var immersiveWish = false
        var chrome = Chrome()

        withObservationTracking {
            display = self.display
            activationKey = GuiPaneReadout.activationKey(
                paneHash: live?.id.hashValue ?? 0,
                promotionGeneration: store.videoPromotionGeneration,
                isVisible: isVisible,
            )
            injectable = model?.canInjectSystemKeys ?? false
            immersiveWish = model?.immersiveEffective ?? false
            chrome = readChrome()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        // ORDER MATTERS. Admission first (it can flip `model.active`, which the surface mounts on),
        // then the pixels, then the gates, then the chrome that describes them.
        applyActivation(key: activationKey)
        if display == .live { mountSurface() } else { unmountSurface(display) }
        push()
        applyImmersiveEdges(injectable: injectable, wish: immersiveWish)
        applyChrome(chrome)
    }

    /// The pure three-state display decision, unchanged from the SwiftUI half.
    private var display: RemoteGUIDisplay {
        guard let model else { return .entryForm }
        return RemoteGUIDisplay.resolve(
            admitted: model.active != nil,
            configured: model.canOpen,
            hasFreeSlot: store.hasFreeVideoSlot(for: paneID),
        )
    }

    /// CAP ADMISSION. The SwiftUI half's `.task(id: activationKey)`: request a slot when on-screen, on
    /// mount AND whenever a sibling frees one (`videoPromotionGeneration` bumps, which changes the
    /// key). NEVER calls `live.setVideoActive` directly — the store enforces the cap and the
    /// `tearingDownVideo` accounting.
    private func applyActivation(key: String) {
        guard key != lastActivationKey else { return }
        lastActivationKey = key
        guard model != nil else { return }
        if isVisible {
            _ = store.activateVideo(paneID)
            // A remount may find the sinks ALREADY live, in which case neither the injectability nor
            // the focus edge fires — so the mount itself has to attempt the re-engage.
            immersiveCapture.autoEngage(model: model, isFocused: isFocused)
        } else {
            store.deactivateVideo(paneID)
        }
    }

    private func unmountSurface(_ display: RemoteGUIDisplay) {
        if surfaceView != nil {
            surfaceHost?.detachSurface()
            surfaceHost = nil
            surfaceView?.removeFromSuperview()
            surfaceView = nil
            mountedDescriptor = nil
        }
        placeholder.isHidden = false
        placeholder.present(display)
    }

    /// The two `.onChange`s that are about the tap rather than the drawing.
    ///
    /// A read-only flip withholds the system-key sink, which is a SUSPENSION exactly like losing
    /// focus; the wish edge is a re-target or a native-fullscreen flip changing the wish under a
    /// mounted view, which must move the tap both ways.
    private func applyImmersiveEdges(injectable: Bool, wish: Bool) {
        if injectable != lastInjectable {
            lastInjectable = injectable
            immersiveCapture.setSuspended(!injectable || !isFocused)
            immersiveCapture.autoEngage(model: model, isFocused: isFocused)
        }
        if wish != lastImmersiveWish {
            lastImmersiveWish = wish
            immersiveCapture.wishChanged(to: wish, model: model, isFocused: isFocused)
        }
    }

    // MARK: - The chrome

    /// Everything drawn over the stream, read once per pass so the bar can never show half of one
    /// update and half of the next.
    private struct Chrome {
        var showControlBar = false
        var hasLatchedMode = false
        var readOnly = false
        var stalled = false
        var stalledAt: Date?
        var telemetry = GuiStreamTelemetry()
        var uploads: [FileUploadProgress] = []
        var pasteFeedback: RemoteWindowModel.PasteFeedback?
        var live = false
    }

    private func readChrome() -> Chrome {
        var chrome = Chrome()
        chrome.readOnly = GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: paneID))
        guard let model else { return chrome }
        chrome.live = model.active != nil
        chrome.showControlBar = GuiPaneReadout.showsControlBar(hasLiveDescriptor: chrome.live)
        chrome.hasLatchedMode = GuiPaneReadout.hasLatchedMode(
            // The model's WISH, not the tap's state: a suspended or not-yet-re-engaged mode must still
            // show its light, or the chip claims a mode is off while it is only paused.
            immersive: model.immersiveEffective,
            viewportLocked: model.viewportLocked,
            audioEnabled: model.audioStreamEnabled,
            streamFpsCap: model.streamFpsCap,
            streamBitrateCeilingBps: model.streamBitrateCeilingBps,
        )
        chrome.stalled = model.isStreamStalled
        chrome.stalledAt = model.streamStalledAt
        chrome.telemetry = GuiStreamTelemetry(
            streamFps: model.streamFps,
            streamKbps: model.streamKbps,
            statsFps: model.statsFps,
            statsPacerDepth: model.statsPacerDepth,
            statsFecPerSec: model.statsFecPerSec,
            statsUnrecoveredPerSec: model.statsUnrecoveredPerSec,
            statsRttMs: model.statsRttMs,
            statsEncodeMs: model.statsEncodeMs,
            statsDecodeMs: model.statsDecodeMs,
            statsHoldMs: model.statsHoldMs,
        )
        chrome.uploads = model.activeUploads
        chrome.pasteFeedback = model.pasteFeedback
        return chrome
    }

    private func applyChrome(_ chrome: Chrome) {
        controlBar.present(
            model: model, store: store, paneID: paneID,
            showStats: showStats, immersiveOn: chrome.hasLatchedMode && model?.immersiveEffective == true,
        )
        MacGuiOverlayFade.set(controlBar, shown: chrome.showControlBar && controlsExpanded)
        collapsedChip.latched = chrome.hasLatchedMode
        MacGuiOverlayFade.set(collapsedChip, shown: chrome.showControlBar && !controlsExpanded)

        stallCaption.present(since: chrome.stalledAt)
        MacGuiOverlayFade.set(stallCaption, shown: chrome.stalled && chrome.live)

        statsReadout.present(chrome.telemetry)
        MacGuiOverlayFade.set(statsReadout, shown: showStats && chrome.live)

        uploadOverlay.present(chrome.uploads)
        MacGuiOverlayFade.set(uploadOverlay, shown: !chrome.uploads.isEmpty)

        MacGuiOverlayFade.set(readOnlyPill, shown: chrome.readOnly)
        MacGuiOverlayFade.set(dropHighlight, shown: isDropTargeted)
        applyPasteBanner(chrome.pasteFeedback, barExpanded: chrome.showControlBar && controlsExpanded)
    }

    /// The one rebuilt overlay: its copy is baked in at init, so a NEW feedback is a new banner.
    private func applyPasteBanner(_ feedback: RemoteWindowModel.PasteFeedback?, barExpanded: Bool) {
        let clearance = barExpanded
            ? Slate.Metric.paneHeaderHeight + Slate.Metric.space2
            : Slate.Metric.space2
        pasteBannerBottom?.constant = -clearance
        guard feedback != pasteBanner?.feedback else { return }
        if let banner = pasteBanner {
            MacGuiOverlayFade.retire(banner)
            pasteBanner = nil
            pasteBannerBottom = nil
        }
        guard let feedback else { return }
        let banner = MacPasteFeedbackBanner(feedback: feedback) { [weak self] in
            self?.model?.dismissPasteFeedback()
        }
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alphaValue = 0
        banner.isHidden = true
        addSubview(banner, positioned: .below, relativeTo: dropHighlight)
        let bottom = banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -clearance)
        NSLayoutConstraint.activate([bottom, banner.centerXAnchor.constraint(equalTo: centerXAnchor)])
        pasteBannerBottom = bottom
        pasteBanner = banner
        MacGuiOverlayFade.set(banner, shown: true)
    }

    private func setControlsExpanded(_ expanded: Bool) {
        guard expanded != controlsExpanded else { return }
        controlsExpanded = expanded
        if isWired { follow() }
    }

    private func setShowStats(_ show: Bool) {
        guard show != showStats else { return }
        showStats = show
        if isWired { follow() }
    }

    /// The one setting that must be LIVE rather than read at mount. `Defaults` is not `@Observable`,
    /// so it cannot ride ``follow()``'s tracking — this is the AppKit reading of the SwiftUI half's
    /// `@Default(.satelliteBackgroundPointer)`, and it re-pushes the GATE rather than remounting,
    /// which is the whole point of `setPaneGates` existing.
    private func followSettings() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            for await value in Defaults.updates(.satelliteBackgroundPointer) {
                guard let self else { return }
                satelliteBackgroundPointer = value
                push()
            }
        }
    }

    // MARK: - The file drop (PATH 4)

    /// Whether this pane accepts an upload at all, from the same pure gate the SwiftUI half reads: a
    /// LIVE DESKTOP pane only. A window or dialog pane must never flash the border for a drag it will
    /// refuse.
    private var isDesktopUploadTarget: Bool {
        GuiPaneReadout.isDesktopUploadTarget(
            kind: paneKind, hasLiveDescriptor: model?.active != nil,
        )
    }

    /// This pane's KIND, resolved once and held.
    ///
    /// ⚠️ Only the KIND is cached; the LIVENESS half of ``isDesktopUploadTarget`` stays a fresh read,
    /// because a stream can go down mid-drag and a pane that stops being able to receive the file has
    /// to stop saying `.copy`. A kind cannot: it is fixed for the life of the pane id.
    ///
    /// The reason it may not be re-read is `draggingUpdated(_:)`, which AppKit fires on EVERY pointer
    /// move for the whole duration of a drag — and `TreeWorkspace.spec(for:)` is a full DFS over every
    /// session, every tab and every split node. Hovering a file over a video pane was re-walking the
    /// entire workspace per mouse-move frame. `nil` is deliberately NOT cached, so a spec that has not
    /// landed yet is asked for again rather than latched absent.
    private var paneKind: PaneKind? {
        if let cachedPaneKind { return cachedPaneKind }
        let kind = store.tree.spec(for: paneID)?.kind
        cachedPaneKind = kind
        return kind
    }

    private var cachedPaneKind: PaneKind?

    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation {
        guard isDesktopUploadTarget else { return [] }
        setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_: NSDraggingInfo) -> NSDragOperation {
        isDesktopUploadTarget ? .copy : []
    }

    override func draggingExited(_: NSDraggingInfo?) { setDropTargeted(false) }

    /// The belt to `draggingExited`'s braces — a drag released outside, or cancelled by the system,
    /// leaves the highlight lit otherwise.
    override func draggingEnded(_: NSDraggingInfo) { setDropTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropTargeted(false)
        return GuiPaneUploads.handleDrop(
            sender.draggingPasteboard.slateDroppedFileURLs(),
            isUploadTarget: isDesktopUploadTarget, model: model,
        )
    }

    private func setDropTargeted(_ targeted: Bool) {
        let wanted = targeted && isDesktopUploadTarget
        guard wanted != isDropTargeted else { return }
        isDropTargeted = wanted
        MacGuiOverlayFade.set(dropHighlight, shown: wanted)
    }
}

// MARK: - The collapsed chip

/// The way back into the control bar: one plate on the stall caption's dim-ground material,
/// bottom-trailing.
///
/// A CLICK target, never hover-reveal — the bottom edge of a video pane is the edge-hover auto-pan
/// strip, so a hover-revealed bar would fight the pan gesture.
///
/// LATCHED IS INK AND WEIGHT HERE, not the accent the SwiftUI half tints it with, and the divergence
/// is deliberate: `MacPlateIconButton` carries the chrome's own rule (a hue carrying state is the
/// pattern this app reversed twice), and primary ink one weight up says "a mode is engaged" in the two
/// channels that survive any theme. What the tint was FOR — no latched mode is ever invisible once the
/// bar is folded away — is kept exactly.
@MainActor
final class MacGuiCollapsedControlsChip: NSView {
    var onExpand: () -> Void = {}

    var latched: Bool {
        get { plate.active }
        set { plate.active = newValue }
    }

    private let plate = MacPlateIconButton(symbolName: SFSymbol.ellipsis.rawValue)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        paint()

        plate.toolTip = GuiPaneReadout.Tooltip.expandControls
        plate.onClick = { [weak self] in self?.onExpand() }
        addSubview(plate)
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.ground
                .slateScalingAlpha(Slate.Opacity.scrim).cgColor
        }
    }
}

// MARK: - The placeholder

/// The non-live states: the cap-gated "video paused" notice, or the calm idle mirror of the
/// pre-admission beat. One glyph, one line, both from `GuiPaneReadout`.
@MainActor
final class MacGuiPlaceholderView: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        paint()

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        label.isSelectable = false
        label.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)

        let column = NSStackView(views: [glyph, label])
        column.orientation = .vertical
        column.spacing = Slate.Metric.space3
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        present(.entryForm)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        repaint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    func present(_ state: RemoteGUIDisplay) {
        label.stringValue = GuiPaneReadout.placeholderLabel(state)
        repaint()
    }

    private func repaint() {
        label.textColor = Slate.Native.Text.primary
        glyph.image = NSImage(systemSymbolName: SFSymbol.display.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.display, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Slate.Native.Text.secondary])),
            )
    }
}

// MARK: - The reveal

/// The chrome's arrival and departure.
///
/// The SwiftUI half spends `.transition(.opacity)` (and, on three of these, a `.move(edge:)`) under
/// `.animation(Slate.Anim.reveal, value:)`. Everything here is pinned by constraints rather than
/// arranged in a stack, so there is no reflow to animate and no neighbour to slide past — the FADE is
/// the whole transition, which is also what the SwiftUI half degrades to for an overlay whose
/// neighbours do not move.
///
/// `isHidden` rides with the alpha rather than replacing it: a fully transparent view still hit-tests,
/// and a control bar that took clicks while invisible would eat the stream's pointer input.
@MainActor
private enum MacGuiOverlayFade {
    static func set(_ view: NSView, shown: Bool) {
        let wanted: CGFloat = shown ? 1 : 0
        guard view.alphaValue != wanted else {
            view.isHidden = !shown
            return
        }
        if shown { view.isHidden = false }
        animate({ view.animator().alphaValue = wanted }, thenHiding: shown ? nil : view)
    }

    static func retire(_ view: NSView) {
        animate({ view.animator().alphaValue = 0 }, thenRemoving: view)
    }

    /// A VIEW, NEVER A CLOSURE, for the reason `MacTerminalLeafView` records at length:
    /// `runAnimationGroup`'s completion handler is `@Sendable` and a bare closure is not, while an
    /// `NSView` crosses freely because `@MainActor` classes are implicitly `Sendable`.
    private static func animate(
        _ body: @escaping () -> Void, thenHiding hiding: NSView? = nil, thenRemoving retiring: NSView? = nil,
    ) {
        let curve = Slate.Motion.reveal
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            context.allowsImplicitAnimation = true
            body()
        } completionHandler: {
            // `MainActor.assumeIsolated` for the reason `MacTerminalLeafView` gives at its own
            // `animate`: the handler is `@Sendable`, both calls below are main-actor isolated, and
            // AppKit runs it on the main thread without having said so in the type.
            MainActor.assumeIsolated {
                hiding?.isHidden = true
                retiring?.removeFromSuperview()
            }
        }
    }
}

// The Objective-C class is the API's, not a preference: `readObjects(forClasses:options:)` takes
// `NSPasteboardReading` conformers and `URL` does not conform. Swift bridges what comes BACK, which
// is why the read goes out through the class and returns value types — the same shape and the same
// reason as `MacPaneDropReceiver`'s provider reads.
// swiftlint:disable:next legacy_objc_type
private let slateDroppableURLClasses: [AnyClass] = [NSURL.self]

private extension NSPasteboard {
    /// The FILE urls on a drag, and only those. `urlReadingFileURLsOnly` is what keeps a web-link drag
    /// out: an upload path that accepted `https://…` would send the host a URL as a file.
    func slateDroppedFileURLs() -> [URL] {
        let objects = readObjects(
            forClasses: slateDroppableURLClasses, options: [.urlReadingFileURLsOnly: true],
        ) ?? []
        return objects.compactMap { $0 as? URL }
    }
}
