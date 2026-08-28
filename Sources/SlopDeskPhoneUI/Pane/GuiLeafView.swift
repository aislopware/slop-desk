// GuiLeafView — the remote-window (PATH 2) pane leaf, in UIKit: the video parallel of
// ``TerminalLeafView`` (docs/62 stage E, the pane-leaf cluster).
//
// It mounts the ``VideoWindowFactory`` seam over the stream's layer, drives the cap-enforced activation
// lifecycle, and draws the chrome over the pixels. The DECISIONS are all somewhere else and unchanged:
// ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)`` picks live / entry-form / cap-gated,
// ``GuiPaneReadout`` owns every gate and string, ``GuiPaneUploads`` routes a drop, ``ClipboardPasteMenu``
// owns the paste enablement and the masked previews, ``BindingRowPlatform`` owns whether a verb exists on
// this platform at all, and ``PaneImmersiveCapture`` owns the tap. What crossed is the drawing and the
// lifecycle.
//
// THREE display states: `.live` mounts the factory, `.entryForm` is the calm idle mirror of the
// pre-admission beat, `.gated` is the cap-saturated notice. SEAM discipline: this target NEVER imports
// `SlopDeskVideoClient`, VideoToolbox or Metal — only the seam types cross, and a headless build that
// registers no factory gets the placeholder.
//
// TWO THINGS A RENDER PASS DID FOR FREE, and they are why this file is longer than the half it replaces:
//
//   • THE GATES. `RemotePaneContext` was rebuilt on every pass, so a read-only flip re-published the
//     injector sinks by simply being re-evaluated. There is no pass here, so ``push()`` calls
//     `RemoteSurfaceHosting.setPaneGates` explicitly. Miss it and a lock stops reaching the host.
//   • THE EDGES. Four `.onChange`s (focus, injectability, the immersive wish, visibility) and one
//     `.task(id:)` become one tracked read plus remembered last-values. The activation key is the same
//     pure ``GuiPaneReadout/activationKey(paneHash:promotionGeneration:isVisible:)`` string, so "did the
//     key change" is still one comparison and not four.
//
// EDGE-TO-EDGE, unlike the terminal leaf's inset: every point of a video pane is remote pixels, so a
// gutter here is wasted stream area rather than a reading margin. The chrome floats over it.
//
// ⚠️ ONE FILE, WHERE THE MAC HAS THREE. `MacGuiLeafView` splits its control bar into
// `MacGuiPaneControls.swift` and its four decorations into `MacGuiPaneOverlays.swift` because those are
// `public` types another AppKit surface could mount. Nothing on the phone mounts them but this leaf, so
// they stay file-private here — the same shape the deleted half had, and the shape the mirror table asks
// for.
//
// ⚠️ NO PLATFORM GATE ANYWHERE IN THE CHROME. Immersive capture's event tap is macOS-only and always will
// be, but that gate is spelled exactly once — inside ``PaneImmersiveCapture``, whose phone half is a no-op
// and whose ``PaneImmersiveCapture/isSupported`` is what keeps the bar from drawing a chip that would do
// nothing. Seven `#if`s through this view would be seven places to write an invisible `#else`.

#if os(iOS)
import Foundation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

// MARK: - The leaf

@MainActor
final class GuiLeafView: UIView {
    // MARK: What the leaf was handed

    private let store: WorkspaceStore
    private let paneID: PaneID
    private var live: LivePaneSession?
    private var isFocused: Bool
    /// Whether this pane is ON-SCREEN (tab active AND not zoom-hidden). Under keep-all-mounted a hidden
    /// tab's leaf is never unmounted, so this — not ``didMoveToWindow()`` — is what frees the
    /// `liveVideoCap` slot and stops the UDP/VT/Metal pipeline off-screen.
    private var isVisible: Bool

    private var model: RemoteWindowModel? { live?.remoteWindow }

    // MARK: The pixels

    /// The seam's view, or the placeholder. Whichever is mounted fills the leaf.
    private var surfaceView: UIView?
    private var surfaceHost: RemoteSurfaceHosting?
    private let placeholder = GuiPlaceholderView()
    /// What ``mountSurface()`` last built for, so a ``follow()`` pass that changed nothing about the
    /// descriptor does not tear a live decode stack down and rebuild it.
    private var mountedDescriptor: RemoteWindowDescriptor?

    // MARK: The chrome — every piece STANDING, faded rather than absent

    private let controlBar = GuiPaneControlBar()
    private let collapsedChip = GuiCollapsedControlsChip()
    private let stallCaption = StreamStallCaption()
    private let statsReadout = GuiStatsReadout()
    private let uploadOverlay = FileUploadOverlay()
    private let dropHighlight = FileDropHighlight()
    private let readOnlyPill: PaneStatusPillView
    /// The ONE piece that is rebuilt: its copy is baked in at init, and it is transient by design.
    private var pasteBanner: PasteFeedbackBanner?
    /// The paste banner clears the control bar when the bar is expanded, so this constant moves.
    private var pasteBannerBottom: NSLayoutConstraint?

    // MARK: Per-pane view state — resets on remount, exactly like the `@State` it replaces

    private var showStats = false
    private var controlsExpanded = false
    private var isDropTargeted = false
    /// The tap must die with this MOUNT, while the on/off WISH lives on the model — which is what makes a
    /// detach/reattach re-engage instead of silently dropping the mode.
    private let immersiveCapture = PaneImmersiveCapture()

    // MARK: The live reads

    /// Supersedes an armed observation. An arm cannot be cancelled, so a stale callback drops itself.
    private var generation = 0
    private var isWired = false
    /// `desktop.satellite-background-pointer`, re-read by ``follow()`` off ``ConfigRevision`` — it
    /// re-pushes the GATE rather than remounting, which is the whole point of `setPaneGates`.
    private var satelliteBackgroundPointer = SettingsKey.satelliteBackgroundPointerEnabled

    /// Last values of the four things the deleted half gave an `.onChange` each. Optional-less: every one
    /// has a well-defined false/empty reading for a pane with no model.
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
        readOnlyPill = PaneStatusPillView(pill: .readOnly) { store.setPaneReadOnly(paneID, false) }
        super.init(frame: .zero)
        build()
        mountSurface()
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // A dynamic `UIColor` on the VIEW re-resolves on a theme flip; only a `CGColor` hung on a layer is
        // flat, which is what the Mac's `updateLayer` + appearance override is spent on.
        backgroundColor = Slate.Native.Surface.terminal

        // ⚠️ THE DROP LIVES ON THE LEAF, and it wins over the pane's own receiver by DEPTH. ``PaneContainerView``
        // mounts this leaf inside ``PaneDropReceiverView``, which carries its own `UIDropInteraction` for the
        // terminal path-inject; UIKit offers a session to the deepest interaction first, so a file dragged
        // over a live desktop pane is an UPLOAD and never a path paste. Same outcome as the Mac, where
        // AppKit's destination walk goes UP from the deepest view and finds this one first.
        addInteraction(UIDropInteraction(delegate: self))

        // THE FLOOR, added before everything else so it is at the BACK: the placeholder shows through
        // whenever no surface is mounted, and the seam's view goes in above it.
        addSubview(placeholder)
        fill(placeholder)

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
        ] as [UIView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.layer.opacity = 0
            overlay.accessibilityElementsHidden = true
            addSubview(overlay)
        }
        fill(dropHighlight)

        let pad = Slate.Metric.space2
        NSLayoutConstraint.activate([
            controlBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingAnchor.constraint(equalTo: collapsedChip.trailingAnchor, constant: pad),
            bottomAnchor.constraint(equalTo: collapsedChip.bottomAnchor, constant: pad),
            // BOTTOM-LEADING for the stall caption: bottom-trailing is the chip's corner, and the two can
            // be on screen at once (a stalled stream still has controls).
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

    private func fill(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Attach / detach, and the one thing that is not symmetric

    /// The UIKit spelling of `.onAppear` / `.onDisappear`, with the SAME asymmetry the terminal leaf
    /// carries and for a stricter reason.
    ///
    /// The OBSERVATION detaches with the view tree; it is idempotent and re-installable.
    ///
    /// The CAP SLOT does not, because a leaf can leave the tree without its pane going away — a split
    /// rearrange re-parents it, and detach/reattach mounts another hosting root for the SAME PaneID while
    /// this one is still coming down. Deactivating here would close the model mid-handoff and race the
    /// replacement's fresh session. Only ``teardown()`` frees the slot, and only after checking the pane
    /// is gone from the tree AND from the detached set.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, superview == nil {
            detach()
        } else if window != nil {
            attach()
        }
    }

    private func attach() {
        guard !isWired else { return }
        isWired = true
        follow()
    }

    private func detach() {
        guard isWired else { return }
        isWired = false
        generation &+= 1
    }

    /// The pane is closed for good.
    ///
    /// The immersive tap comes down FIRST and unconditionally: an unmounted pane that keeps swallowing the
    /// keyboard has no owner left to disengage it. ``PaneImmersiveCapture/teardown()`` is the verb that
    /// drops the tap WITHOUT clearing the model's wish, so a reattach still re-engages.
    ///
    /// The chrome's own beats come down here too — the stall clock and the display refresh are stored
    /// `Task`s, which is the one lifetime UIKit does not end for us (docs/62 hazard 6).
    func teardown() {
        detach()
        immersiveCapture.teardown()
        stallCaption.teardown()
        controlBar.teardown()
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
        // IMMERSIVE SAFETY: focus drives a SUSPENSION, never a tear-down. Losing focus pauses swallowing;
        // regaining it resumes by itself, so the user's toggle survives a popover blip.
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
        // A REBUILD IS A TEARDOWN. The hosting view owns UDP sockets, a decoder and a display link, so
        // remounting for an unchanged descriptor would reset a live stream mid-frame — the identity hazard
        // spelled as "never reconstruct the hosted view across panes".
        if descriptor == mountedDescriptor, surfaceView != nil || descriptor == nil { return }
        surfaceHost?.detachSurface()
        surfaceHost = nil
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        mountedDescriptor = descriptor

        guard let descriptor else { return }
        guard let host = VideoWindowFactory.make(descriptor, context: paneContext()) else { return }
        surfaceHost = host
        fillSurface(host.surfaceView)
    }

    /// The per-render context the deleted half rebuilt on every pass. Built here at MOUNT, and its three
    /// gates re-pushed by ``push()`` afterwards — the sinks below are bound once because they are bound to
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
            // VIEWPORT CONTROLS: zoom / pan-lock — pure CLIENT compositor ops, so the seam binds this sink
            // even on a read-only pane (unlike the host-affecting key/resize sinks).
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

    /// THE ONLY WAY A READ-ONLY LOCK REACHES THE HOST on this canvas. A render pass got this for free;
    /// here it is a call, and every edge that can change one of the three gates makes it.
    private func push() {
        surfaceHost?.setPaneGates(
            isActive: isFocused,
            inputEnabled: !store.isReadOnly(for: paneID),
            backgroundPointer: store.tree.isDetached(paneID) && satelliteBackgroundPointer,
        )
    }

    /// Mount the seam's view between the placeholder and the chrome.
    ///
    /// `insertSubview(_:belowSubview:)` rather than a plain `addSubview`, because the chrome was added in
    /// ``build()`` and a plain add would put the remote pixels ON TOP of the control bar — which would not
    /// merely look wrong, it would put an opaque stream layer over every overlay in the file.
    private func fillSurface(_ view: UIView) {
        insertSubview(view, belowSubview: controlBar)
        surfaceView = view
        fill(view)
        placeholder.isHidden = true
    }

    // MARK: - The live read

    /// ONE tracked read of everything this leaf draws, activates on, or triggers an immersive edge from —
    /// re-armed by its own `onChange`, superseded by generation.
    ///
    /// One arm rather than one per concern for the same reason the terminal leaf gives:
    /// `withObservationTracking` fires on the FIRST change to anything it read, so N arms cost N callbacks
    /// for one edit and give nothing back.
    private func follow() {
        generation &+= 1
        let generation = generation

        var display = RemoteGUIDisplay.entryForm
        var activationKey = ""
        var injectable = false
        var immersiveWish = false
        var chrome = Chrome()

        withObservationTracking {
            // The config-file edge — `AppConfig` is a plain locked global, so the setting below is
            // observable only through the revision, and the read must stay INSIDE this block or the view
            // silently unsubscribes. See ``ConfigRevision``.
            _ = ConfigRevision.shared.generation
            satelliteBackgroundPointer = SettingsKey.satelliteBackgroundPointerEnabled
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
            // The hop is required: `onChange` runs INSIDE the mutation, so re-arming from it would read
            // half-written state.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        // ORDER MATTERS. Admission first (it can flip `model.active`, which the surface mounts on), then
        // the pixels, then the gates, then the chrome that describes them.
        applyActivation(key: activationKey)
        if display == .live { mountSurface() } else { unmountSurface(display) }
        push()
        applyImmersiveEdges(injectable: injectable, wish: immersiveWish)
        applyChrome(chrome)
    }

    /// The pure three-state display decision, unchanged from the deleted half.
    private var display: RemoteGUIDisplay {
        guard let model else { return .entryForm }
        return RemoteGUIDisplay.resolve(
            admitted: model.active != nil,
            configured: model.canOpen,
            hasFreeSlot: store.hasFreeVideoSlot(for: paneID),
        )
    }

    /// CAP ADMISSION. The deleted half's `.task(id: activationKey)`: request a slot when on-screen, on
    /// mount AND whenever a sibling frees one (`videoPromotionGeneration` bumps, which changes the key).
    /// NEVER calls `live.setVideoActive` directly — the store enforces the cap and the `tearingDownVideo`
    /// accounting. iOS resume re-activates `wasVideoActiveBeforePause` in `LivePaneSession.resume`, so
    /// this is idempotent there.
    private func applyActivation(key: String) {
        guard key != lastActivationKey else { return }
        lastActivationKey = key
        guard model != nil else { return }
        if isVisible {
            _ = store.activateVideo(paneID)
            // A remount may find the sinks ALREADY live, in which case neither the injectability nor the
            // focus edge fires — so the mount itself has to attempt the re-engage.
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
    /// A read-only flip withholds the system-key sink, which is a SUSPENSION exactly like losing focus;
    /// the wish edge is a re-target or a fullscreen flip changing the wish under a mounted view, which
    /// must move the tap both ways.
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

    /// Everything drawn over the stream, read once per pass so the bar can never show half of one update
    /// and half of the next.
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
        GuiOverlayFade.set(controlBar, shown: chrome.showControlBar && controlsExpanded)
        collapsedChip.latched = chrome.hasLatchedMode
        GuiOverlayFade.set(collapsedChip, shown: chrome.showControlBar && !controlsExpanded)

        stallCaption.present(since: chrome.stalledAt)
        GuiOverlayFade.set(stallCaption, shown: chrome.stalled && chrome.live)

        statsReadout.present(chrome.telemetry)
        GuiOverlayFade.set(statsReadout, shown: showStats && chrome.live)

        uploadOverlay.present(chrome.uploads)
        GuiOverlayFade.set(uploadOverlay, shown: !chrome.uploads.isEmpty)

        GuiOverlayFade.set(readOnlyPill, shown: chrome.readOnly)
        GuiOverlayFade.set(dropHighlight, shown: isDropTargeted)
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
            GuiOverlayFade.retire(banner)
            pasteBanner = nil
            pasteBannerBottom = nil
        }
        guard let feedback else { return }
        let banner = PasteFeedbackBanner(feedback: feedback) { [weak self] in
            self?.model?.dismissPasteFeedback()
        }
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.layer.opacity = 0
        insertSubview(banner, belowSubview: dropHighlight)
        let bottom = banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -clearance)
        NSLayoutConstraint.activate([bottom, banner.centerXAnchor.constraint(equalTo: centerXAnchor)])
        pasteBannerBottom = bottom
        pasteBanner = banner
        GuiOverlayFade.set(banner, shown: true)
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

    // MARK: - The file drop (PATH 4)

    /// Whether this pane accepts an upload at all, from the same pure gate: a LIVE DESKTOP pane only. A
    /// window or dialog pane must never flash the border for a drag it will refuse.
    fileprivate var isDesktopUploadTarget: Bool {
        GuiPaneReadout.isDesktopUploadTarget(
            kind: paneKind, hasLiveDescriptor: model?.active != nil,
        )
    }

    /// This pane's KIND, resolved once and held.
    ///
    /// ⚠️ Only the KIND is cached; the LIVENESS half of ``isDesktopUploadTarget`` stays a fresh read,
    /// because a stream can go down mid-drag and a pane that stops being able to receive the file has to
    /// stop saying `.copy`. A kind cannot: it is fixed for the life of the pane id.
    ///
    /// The reason it may not be re-read is `sessionDidUpdate(_:)`, which UIKit fires CONTINUOUSLY while
    /// the session is inside the view — including when the finger stops dead — and `TreeWorkspace.spec(for:)`
    /// is a full DFS over every session, every tab and every split node. `nil` is deliberately NOT cached,
    /// so a spec that has not landed yet is asked for again rather than latched absent.
    private var paneKind: PaneKind? {
        if let cachedPaneKind { return cachedPaneKind }
        let kind = store.tree.spec(for: paneID)?.kind
        cachedPaneKind = kind
        return kind
    }

    private var cachedPaneKind: PaneKind?

    fileprivate func setDropTargeted(_ targeted: Bool) {
        let wanted = targeted && isDesktopUploadTarget
        guard wanted != isDropTargeted else { return }
        isDropTargeted = wanted
        GuiOverlayFade.set(dropHighlight, shown: wanted)
    }

    /// Hand the dropped file urls to ``GuiPaneUploads/handleDrop(_:isUploadTarget:model:)``, which owns
    /// the routing and the dedicated PATH-4 connection.
    fileprivate func commitDrop(_ urls: [URL]) {
        _ = GuiPaneUploads.handleDrop(
            urls, isUploadTarget: isDesktopUploadTarget, model: model,
        )
    }
}

// MARK: - The drop's five callbacks

/// ⚠️ THE LOAD IS ASYNCHRONOUS, and that is the one genuine divergence from the AppKit half.
/// `performDragOperation` reads its pasteboard synchronously and returns a `Bool` the drag session
/// believes; `UIDropInteraction` hands over `NSItemProvider`s and `loadObjects(ofClass:)` answers on a
/// later turn. So the commit cannot report success to UIKit — it reports acceptance, and the routing
/// happens in the completion. That is what the API is FOR: a `UIDropSession`'s providers are
/// session-owned and outlive the callback, which is also why nothing is copied out first.
extension GuiLeafView: UIDropInteractionDelegate {
    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        isDesktopUploadTarget && session.canLoadObjects(ofClass: NSURL.self)
    }

    func dropInteraction(_: UIDropInteraction, sessionDidEnter _: UIDropSession) {
        setDropTargeted(true)
    }

    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: isDesktopUploadTarget ? .copy : .forbidden)
    }

    func dropInteraction(_: UIDropInteraction, sessionDidExit _: UIDropSession) {
        setDropTargeted(false)
    }

    /// The belt to `sessionDidExit`'s braces — a drag released outside, or cancelled by the system, leaves
    /// the highlight lit otherwise. The AppKit half spends `draggingEnded` on exactly this.
    func dropInteraction(_: UIDropInteraction, sessionDidEnd _: UIDropSession) {
        setDropTargeted(false)
    }

    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        setDropTargeted(false)
        // The Objective-C class is the API's, not a preference: `loadObjects(ofClass:)` takes an
        // `NSItemProviderReading` conformer and `URL` does not conform. Swift bridges what comes BACK,
        // which is why the read goes out through the class and returns value types — the same shape and
        // the same reason as `MacGuiLeafView`'s `slateDroppedFileURLs()`.
        // swiftlint:disable:next legacy_objc_type
        session.loadObjects(ofClass: NSURL.self) { [weak self] objects in
            let urls = objects.compactMap { ($0 as? NSURL) as URL? }.filter(\.isFileURL)
            // `loadObjects` calls back on the main queue, which UIKit documents and the type does not say.
            MainActor.assumeIsolated { self?.commitDrop(urls) }
        }
    }
}

// MARK: - The paste plate

/// PASTE-AS-KEYSTROKES menu: the affordance making ``RemoteWindowModel/pasteAsKeystrokes(_:)`` + the
/// store's ``WorkspaceStore/clipboardRing`` REACHABLE in a remote-GUI pane — a plain ⌘V there forwards a
/// raw Cmd+V that pastes the HOST clipboard, so local text (a password for the auto-spawned dialog pane,
/// say) could never reach a remote field. "Paste as Keystrokes" types the CURRENT local clipboard; the
/// "Clipboard Ring" submenu lists recent clips with classifier-aware previews (secrets masked). Disabled
/// while the pane cannot type. Mirrors the ⌥⌘V chord + palette command.
///
/// Nothing in here reads the clipboard's CONTENT except the paste row's ACTION: enablement asks a probe
/// (see ``canPasteCurrent``) and the ring submenu reads the app's own recorded history, not the board.
@MainActor
private final class GuiPastePlateMenu {
    let plate: SlatePlateVerbButton

    /// ⚠️ WEAK, AND RE-POINTED BY ``GuiPaneControlBar/present(model:store:paneID:showStats:immersiveOn:)``.
    /// A pane OUTLIVES its session: `setLive(_:)` exists on the leaf's seam precisely because a reconnect
    /// or a host restart hands the same pane a NEW ``RemoteWindowModel``. A plate built once and holding
    /// the first one strongly would keep typing into the dead session — silently, since the menu still
    /// opens and the rows still enable. The Mac has no equivalent hazard because every one of its rows
    /// reads `self?.model` through the bar at click time.
    weak var model: RemoteWindowModel?
    private let store: WorkspaceStore

    init(model: RemoteWindowModel, store: WorkspaceStore) {
        self.model = model
        self.store = store
        // A holder so `itemsAtOpen` can reach the two dependencies without capturing a half-built `self`.
        let plate = slatePlateMenuButton(
            symbol: .documentOnClipboard, help: GuiPaneReadout.Tooltip.paste, itemsAtOpen: { [] },
        )
        self.plate = plate
        plate.menu = UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { [weak self] complete in
                MainActor.assumeIsolated { complete(self?.rows() ?? []) }
            },
        ])
    }

    /// Whether "Paste as Keystrokes" (types the current clipboard) is enabled right now — from the store's
    /// non-prompting PROBE, NEVER from a content read.
    ///
    /// ⚠️ STILL A PROBE, THOUGH THE ORIGINAL REASON HAS EXPIRED. On iOS a read of the clipboard's CONTENT
    /// for text this app did not write raises a modal "Allow Paste?" alert. The deleted half evaluated its
    /// menu WITH the enclosing body, so calling ``WorkspaceStore/currentLocalClipboard()`` here put that
    /// alert on screen unprompted on every render (increment 78); `UIDeferredMenuElement.uncached` now
    /// runs its provider at OPEN, which is the same moment `macPlateMenuButton`'s `itemsAtOpen` names, so
    /// the framework no longer forces the weaker question. It stays anyway, because opening a menu is a
    /// weaker statement of intent than tapping "Paste": the tap IS the paste the user asked for, and that
    /// is the one moment iOS permits the read without ambushing anyone. `slopdesk-invariants`'
    /// `phone_parity::the_paste_plate_asks_a_silent_question` pins the shape.
    var canPasteCurrent: Bool {
        guard let model else { return false }
        return ClipboardPasteMenu.canPaste(
            canPasteKeystrokes: model.canPasteKeystrokes, clipboardHasText: store.localClipboardHasText(),
        )
    }

    /// The menu, built at OPEN so the ring it offers is the one recorded NOW.
    private func rows() -> [UIMenuElement] {
        let paste = slateMenuRow("Paste as Keystrokes", enabled: canPasteCurrent) { [weak self] in
            guard let self else { return }
            // The CONTENT read lives HERE, inside the action. It is also the read that fills the ring —
            // `currentLocalClipboard()` records what it returns.
            guard let model, let text = store.currentLocalClipboard(),
                  ClipboardPasteMenu.isPastable(text) else { return }
            model.pasteAsKeystrokes(text)
        }
        let clips = ClipboardPasteMenu.rows(store.clipboardRing)
        guard !clips.isEmpty else {
            return [paste, slateMenuRow("No recent clips", enabled: false)]
        }
        let ring = clips.map { row in
            // The LABEL is the masked / truncated preview; the full clip is what gets typed and is never
            // shown anywhere.
            slateMenuRow(row.label, enabled: model?.canPasteKeystrokes ?? false) { [weak self] in
                self?.model?.pasteAsKeystrokes(row.text)
            }
        }
        return [paste, UIMenu(title: "Clipboard Ring", children: ring)]
    }
}

// MARK: - The display switcher

/// The desktop pane's DISPLAY SWITCHER: a menu of the host's online displays — picking one re-hellos the
/// SAME pane at that display. The current display is check-marked; a refresh row covers hot-plugged
/// monitors.
///
/// The deleted half kicked the first discovery from a `.task` on mount. Here that is a stored `Task` the
/// bar starts once the plate is first shown and cancels from its teardown (docs/62 hazard 6) — a refresh
/// fired only at menu-open would leave the first open empty, since the provider is synchronous and the
/// discovery is not.
@MainActor
private final class GuiDisplaySwitcherPlate {
    let plate: SlatePlateVerbButton

    /// ⚠️ WEAK, AND RE-POINTED BY THE BAR, for the reason ``GuiPastePlateMenu/model`` records: a pane
    /// outlives its session, so a plate holding the first model strongly would keep switching a display
    /// on a session nobody is watching.
    weak var model: RemoteWindowModel? {
        didSet {
            guard model !== oldValue, model != nil else { return }
            // A NEW session has its own display roster, and the plate is already on screen — so the
            // discovery that ``init`` kicked for the first one has to be kicked again for this one.
            refresh()
        }
    }

    private var discovery: Task<Void, Never>?

    init(model: RemoteWindowModel) {
        self.model = model
        let plate = slatePlateMenuButton(
            symbol: .display, help: GuiPaneReadout.Tooltip.displaySwitcher, itemsAtOpen: { [] },
        )
        self.plate = plate
        plate.menu = UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { [weak self] complete in
                MainActor.assumeIsolated { complete(self?.rows() ?? []) }
            },
        ])
        refresh()
    }

    func teardown() {
        discovery?.cancel()
        discovery = nil
    }

    /// Ask the host for its displays, superseding any ask still in flight.
    private func refresh() {
        discovery?.cancel()
        discovery = Task { [weak self] in await self?.model?.refreshDisplays() }
    }

    private func rows() -> [UIMenuElement] {
        var listed: [UIMenuElement] = []
        let displays = model?.availableDisplays ?? []
        if displays.isEmpty {
            listed.append(slateMenuRow("No display list from host", enabled: false))
        } else {
            for (index, display) in displays.enumerated() {
                listed.append(slateMenuRow(
                    display.displayLabel(ordinal: index + 1),
                    checked: display.displayID == model?.desktopDisplayID,
                ) { [weak self] in self?.model?.switchDisplay(to: display.displayID) })
            }
        }
        // A run fenced off from its neighbours, which UIKit spells as an inline section rather than as a
        // separator element — there is no divider OBJECT to place.
        return [
            slateMenuSection(listed),
            slateMenuSection([slateMenuRow("Refresh Displays") { [weak self] in
                self?.refresh()
            }]),
        ]
    }
}

// MARK: - The footer control bar

/// The bottom control strip for a live remote-window pane: window verbs, viewport verbs, stream state and
/// the two latched modes, kept OUT of the pane content.
///
/// GROUPED BY KIND, and the grouping is the deleted half's exactly: everything LEFT of the spacer is a
/// COMMAND (momentary — press, something happens, nothing latches), everything RIGHT carries STATE (a
/// toggle whose accent is a live status light). One rule for the eye — an accent-tinted plate can only
/// ever appear on the right. Groups are `space1`-tight inside and `space3`-separated, so the rhythm does
/// the grouping and no divider ornament is needed.
///
/// THE BAR IS BUILT ONCE AND UPDATED, NEVER REBUILT. Thirteen plates with conditional presence is the
/// shape that tempts a wholesale rebuild on every model change, and it is wrong here for the same reason
/// it is wrong on the Mac: these plates carry a hover state (iPadOS with a trackpad has hover exactly as
/// the Mac does), so rebuilding under the pointer drops the hover of the plate being aimed at.
///
/// ⚠️ FOUR VERBS ARE TWO BUTTONS EACH, and that is forced rather than chosen. ``SlatePlateVerbButton``
/// takes its `symbol` as a `let` — the Mac's `MacPlateIconButton.symbolName` is settable and flips in
/// place — so detach⇄reattach, speaker on/off, eye/eye-slash and lock open/closed are each a PAIR of
/// standing plates with mutually exclusive `isHidden`. Rebuilding one plate with the other glyph would
/// have been the alternative, and it is the rebuild this bar exists to avoid.
@MainActor
private final class GuiPaneControlBar: UIView {
    /// Fold the bar back into the leaf's corner chip. The leaf owns that state, so this is a callback
    /// rather than something the bar decides.
    var onCollapse: () -> Void = {}
    /// Toggle the in-pane telemetry chip — also the leaf's state, for the same reason.
    var onToggleStats: () -> Void = {}
    /// Toggle immersive system-key capture. The capture object lives above this view.
    var onToggleImmersive: () -> Void = {}

    /// The two menu plates are built with their model, so they arrive with the first `present(...)` that
    /// has one and are kept after.
    private var pasteMenu: GuiPastePlateMenu?
    private var displayMenu: GuiDisplaySwitcherPlate?

    private let detach = SlatePlateVerbButton(symbol: .macwindowOnRectangle)
    private let reattach = SlatePlateVerbButton(symbol: .macwindowAndPointerArrow)
    private let fit = SlatePlateVerbButton(symbol: .rectangleArrowtriangle2Inward)
    private let zoomOut = SlatePlateVerbButton(symbol: .minusMagnifyingglass)
    private let actualSize = SlatePlateVerbButton(symbol: ._1Magnifyingglass)
    private let zoomIn = SlatePlateVerbButton(symbol: .plusMagnifyingglass)
    private let stats = SlatePlateVerbButton(symbol: .chartBarXaxis)
    private let quality = SlatePlateVerbButton(symbol: .gaugeWithDotsNeedle67percent)
    private let audioOn = SlatePlateVerbButton(symbol: .speakerWave2)
    private let audioOff = SlatePlateVerbButton(symbol: .speakerSlash)
    private let privacyOn = SlatePlateVerbButton(symbol: .eyeSlashFill)
    private let privacyOff = SlatePlateVerbButton(symbol: .eye)
    private let immersive = SlatePlateVerbButton(symbol: .command)
    private let lockClosed = SlatePlateVerbButton(symbol: .lockFill)
    private let lockOpen = SlatePlateVerbButton(symbol: .lockOpen)
    private let collapse = SlatePlateVerbButton(symbol: .chevronDown)

    private let commands = UIStackView()
    private let viewport = UIStackView()
    private let streamState = UIStackView()
    private let modeState = UIStackView()
    private let row = UIStackView()
    private let hairline = UIView()

    /// The live snapshot the menus and the popover read at OPEN. Held rather than passed because a menu is
    /// built when the user taps it, which is always later than the `present(...)` that armed it.
    private var model: RemoteWindowModel?
    private var store: WorkspaceStore?
    private var paneID: PaneID?

    private typealias Tip = GuiPaneReadout.Tooltip

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.face // FLAT: bar background == pane background
        build()
        wire()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The display discovery is a stored `Task`, so the pane's close has to end it.
    func teardown() {
        displayMenu?.teardown()
    }

    private func build() {
        for (group, members) in [
            (commands, [detach, reattach]),
            (viewport, [fit, zoomOut, actualSize, zoomIn]),
            (streamState, [stats, quality, audioOn, audioOff, privacyOn, privacyOff]),
            (modeState, [immersive, lockClosed, lockOpen]),
        ] {
            group.axis = .horizontal
            group.spacing = Slate.Metric.space1
            group.alignment = .center
            for member in members { group.addArrangedSubview(member) }
        }

        // `space3` BETWEEN groups against `space1` inside them: the rhythm is what says these are four
        // kinds of thing, which is why there is no divider ornament anywhere in this bar.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for member in [commands, viewport, spacer, streamState, modeState, collapse] as [UIView] {
            row.addArrangedSubview(member)
        }
        row.axis = .horizontal
        row.spacing = Slate.Metric.space3
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        hairline.backgroundColor = Slate.Native.Line.divider

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.paneHeaderHeight),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),
        ])
    }

    private func wire() {
        for plate in [detach, reattach] {
            plate.addAction(UIAction { [weak self] _ in
                guard let self, let store, let paneID else { return }
                if store.tree.isDetached(paneID) {
                    store.reattachPane(paneID)
                } else {
                    store.detachPaneToWindow(paneID)
                }
            }, for: .touchUpInside)
        }
        act(fit) { $0.sendViewport(.fitToPane) }
        act(zoomOut) { $0.sendViewport(.zoomOut) }
        act(actualSize) { $0.sendViewport(.reset) }
        act(zoomIn) { $0.sendViewport(.zoomIn) }
        stats.addAction(UIAction { [weak self] _ in self?.onToggleStats() }, for: .touchUpInside)
        quality.addAction(UIAction { [weak self] _ in self?.dropTunePopover() }, for: .touchUpInside)
        for plate in [audioOn, audioOff] {
            act(plate) { $0.applyAudioEnabled(!$0.audioStreamEnabled) }
        }
        for plate in [privacyOn, privacyOff] {
            act(plate) { $0.applyPrivacyEnabled(!$0.privacyEnabled) }
        }
        immersive.addAction(UIAction { [weak self] _ in self?.onToggleImmersive() }, for: .touchUpInside)
        for plate in [lockClosed, lockOpen] {
            act(plate) { $0.toggleViewportLock() }
        }
        collapse.addAction(UIAction { [weak self] _ in self?.onCollapse() }, for: .touchUpInside)

        collapse.help = Tip.collapseControls
        fit.help = Tip.fitToPane
        zoomOut.help = Tip.zoomOut
        actualSize.help = Tip.actualSize
        zoomIn.help = Tip.zoomIn
        immersive.help = Tip.immersiveOff
        quality.help = Tip.streamQuality
    }

    /// A verb that acts on whatever model the bar is pointed at right now.
    private func act(_ plate: SlatePlateVerbButton, _ body: @escaping (RemoteWindowModel) -> Void) {
        plate.addAction(UIAction { [weak self] _ in
            guard let model = self?.model else { return }
            body(model)
        }, for: .touchUpInside)
    }

    /// The stream-quality sheet.
    ///
    /// ⚠️ A `UIViewController` IS REQUIRED, and nothing in this view tree is one — the phone's pane column
    /// is views all the way down below ``ContentColumnViewController``. So the presenter is found by
    /// walking the responder chain, which is the same walk `UIKit` itself does for a `UIMenu`. Left to
    /// ADAPT: a popover on a regular-width iPad, a sheet on an iPhone, which is exactly what the deleted
    /// half's `.popover` degraded to.
    private func dropTunePopover() {
        guard let model, let presenter = presentingController() else { return }
        let sheet = GuiStreamTuneController(
            fpsCap: model.streamFpsCap,
            bitrateCapMbps: GuiPaneReadout.mbps(fromBps: model.streamBitrateCeilingBps),
            onFps: { model.applyStreamSettings(fpsCap: $0, bitrateCeilingBps: model.streamBitrateCeilingBps) },
            onBitrate: {
                model.applyStreamSettings(
                    fpsCap: model.streamFpsCap, bitrateCeilingBps: GuiPaneReadout.bps(fromMbps: $0),
                )
            },
        )
        sheet.modalPresentationStyle = .popover
        sheet.popoverPresentationController?.sourceView = quality
        sheet.popoverPresentationController?.sourceRect = quality.bounds
        // `.up` — the bar is at the pane's BOTTOM, so the popover opens upward into the content and not
        // off the screen edge.
        sheet.popoverPresentationController?.permittedArrowDirections = .down
        presenter.present(sheet, animated: true)
    }

    private func presentingController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    // MARK: The one update path

    /// Point the bar at a pane and settle every plate from one snapshot.
    func present(
        model: RemoteWindowModel?, store: WorkspaceStore, paneID: PaneID,
        showStats: Bool, immersiveOn: Bool,
    ) {
        self.model = model
        self.store = store
        self.paneID = paneID
        adoptMenus(model: model, store: store)

        // ── WINDOW COMMANDS
        pasteMenu?.plate.isHidden = model == nil
        displayMenu?.plate.isHidden = model?.desktopDisplayID == nil
        // The detach verb's PRESENCE is data, read from the same `binding_rows` declaration that decides
        // whether ⌥⌘P is bound and whether the palette lists it. A platform gate here would be a fourth
        // place for that answer to drift.
        let listed = BindingRowPlatform.lists("pane.detach")
        let detached = store.tree.isDetached(paneID)
        detach.isHidden = !listed || detached
        reattach.isHidden = !listed || !detached
        detach.help = Tip.detach
        reattach.help = Tip.reattach
        commands.isHidden = commands.arrangedSubviews.allSatisfy(\.isHidden)

        // ── VIEWPORT COMMANDS. Withheld while the viewport is locked: they would re-anchor the pan or
        // read as live controls the lock does not actually hold, so dimming them sends the eye to the lock
        // — which stays live, and stays OUTSIDE this cluster. `Slate.Opacity.withheld` is the rung, and it
        // names this very cluster as one of the three that spent it as a raw literal first.
        let canViewport = model?.canControlViewport == true
        viewport.isHidden = !canViewport
        let locked = model?.viewportLocked == true
        for plate in [fit, zoomOut, actualSize, zoomIn] { plate.isEnabled = !locked }
        viewport.alpha = locked ? Slate.Opacity.withheld : 1

        // ── STREAM STATE
        stats.isHidden = model == nil
        stats.tint = showStats ? Slate.Native.State.accent : Slate.Native.Text.icon
        stats.help = showStats ? Tip.hideStats : Tip.showStats

        quality.isHidden = model?.canAdjustStreamSettings != true
        let tuned = (model?.streamFpsCap ?? 0) != 0 || (model?.streamBitrateCeilingBps ?? 0) != 0
        quality.tint = tuned ? Slate.Native.State.accent : Slate.Native.Text.icon

        // The speaker stays VISIBLE while on even when the sink is withheld, so the status light never
        // vanishes mid-stream; the verb is what gets refused. The privacy shield below follows the same
        // rule, and so does immersive.
        let audioIsOn = model?.audioStreamEnabled == true
        let audioListed = model?.canToggleAudio == true || audioIsOn
        audioOn.isHidden = !(audioListed && audioIsOn)
        audioOff.isHidden = !(audioListed && !audioIsOn)
        audioOn.tint = Slate.Native.State.accent
        audioOn.help = Tip.muteAudio
        audioOff.help = Tip.playAudio
        for plate in [audioOn, audioOff] { plate.isEnabled = model?.canToggleAudio == true }

        let privacyIsOn = model?.privacyEnabled == true
        let isDesktop = store.tree.spec(for: paneID)?.kind == .desktop
        let privacyListed = isDesktop && (model?.canTogglePrivacy == true || privacyIsOn)
        privacyOn.isHidden = !(privacyListed && privacyIsOn)
        privacyOff.isHidden = !(privacyListed && !privacyIsOn)
        privacyOn.tint = Slate.Native.State.accent
        privacyOn.help = Tip.privacyOff
        privacyOff.help = Tip.privacyOn
        for plate in [privacyOn, privacyOff] { plate.isEnabled = model?.canTogglePrivacy == true }

        streamState.isHidden = streamState.arrangedSubviews.allSatisfy(\.isHidden)

        // ── MODE STATE. The immersive chip exists only where there is an event tap to arm — capability as
        // DATA, never a compile-time gate, so a chip is never drawn over a no-op.
        let immersiveListed = PaneImmersiveCapture.isSupported
            && (model?.canInjectSystemKeys == true || immersiveOn)
        immersive.isHidden = !immersiveListed
        immersive.tint = immersiveOn ? Slate.Native.State.accent : Slate.Native.Text.icon
        immersive.help = immersiveOn ? Tip.immersiveOn : Tip.immersiveOff

        lockClosed.isHidden = !(canViewport && locked)
        lockOpen.isHidden = !(canViewport && !locked)
        lockClosed.tint = Slate.Native.State.accent
        lockClosed.help = Tip.unlockViewport
        lockOpen.help = Tip.lockViewport

        // Gated as a WHOLE so an all-absent mode row leaves no stray double gap in the bar's rhythm.
        modeState.isHidden = modeState.arrangedSubviews.allSatisfy(\.isHidden)
    }

    /// The two menu plates need a model to hold, so they are built on the first pass that has one and
    /// inserted at the head of the command group in the deleted half's order (paste, then display).
    ///
    /// ⚠️ AND RE-POINTED ON EVERY PASS AFTERWARDS. The plates are built once — that is this bar's whole
    /// rule — but the MODEL under them is not the pane's for life: `setLive(_:)` hands the same pane a
    /// fresh ``RemoteWindowModel`` on a reconnect or a host restart. The plain verbs re-read `self.model`
    /// at press, so they follow by themselves; a menu built at open reads what its own plate holds, which
    /// is why these two need saying. Both sides are weak, so a session that goes away takes its menu's
    /// reference with it rather than being kept alive by a plate.
    private func adoptMenus(model: RemoteWindowModel?, store: WorkspaceStore) {
        guard let model else { return }
        if pasteMenu == nil {
            let menu = GuiPastePlateMenu(model: model, store: store)
            pasteMenu = menu
            commands.insertArrangedSubview(menu.plate, at: 0)
        }
        if displayMenu == nil, model.desktopDisplayID != nil {
            let menu = GuiDisplaySwitcherPlate(model: model)
            displayMenu = menu
            commands.insertArrangedSubview(menu.plate, at: pasteMenu == nil ? 0 : 1)
        }
        pasteMenu?.model = model
        displayMenu?.model = model
    }
}

// MARK: - The collapsed chip

/// The way back into the control bar: one plate on the stall caption's dim-ground material,
/// bottom-trailing.
///
/// A TAP target, never hover-reveal — the bottom edge of a video pane is the edge-hover auto-pan strip, so
/// a hover-revealed bar would fight the pan gesture, and a phone has no hover to reveal with at all.
///
/// LATCHED IS THE ACCENT here, not the Mac's ink-and-weight. That divergence is the Mac's:
/// `MacPlateIconButton` carries the chrome's own rule about a hue never carrying state, while
/// ``SlatePlateVerbButton``'s own header names the accent tint as the GUI control bar's idiom — and this
/// chip inherits the bar's tint by construction, so it says what the bar would have said.
@MainActor
private final class GuiCollapsedControlsChip: UIView {
    var onExpand: () -> Void = {}

    var latched: Bool = false {
        didSet {
            guard latched != oldValue else { return }
            plate.tint = latched ? Slate.Native.State.accent : Slate.Native.Text.icon
        }
    }

    private let plate = SlatePlateVerbButton(
        symbol: .ellipsis, help: GuiPaneReadout.Tooltip.expandControls,
    )

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        backgroundColor = Slate.Native.Surface.ground.slateScalingAlpha(Slate.Opacity.scrim)

        plate.addAction(UIAction { [weak self] _ in self?.onExpand() }, for: .touchUpInside)
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
}

// MARK: - The placeholder

/// The non-live states: the cap-gated "video paused" notice, or the calm idle mirror of the pre-admission
/// beat. One glyph, one line, both from ``GuiPaneReadout``.
@MainActor
private final class GuiPlaceholderView: UIView {
    private let glyph = UIImageView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.terminal

        glyph.contentMode = .center
        glyph.isAccessibilityElement = false
        glyph.image = UIImage(
            systemName: SFSymbol.display.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.display, weight: .regular,
            ),
        )
        // `tintColor` on a `UIImageView` re-resolves on a theme flip by itself, which is the whole of the
        // Mac half's `repaint()` on the appearance hook.
        glyph.tintColor = Slate.Native.Text.secondary
        label.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        label.textColor = Slate.Native.Text.primary

        let column = UIStackView(arrangedSubviews: [glyph, label])
        column.axis = .vertical
        column.spacing = Slate.Metric.space3
        column.alignment = .center
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

    func present(_ state: RemoteGUIDisplay) {
        label.text = GuiPaneReadout.placeholderLabel(state)
    }
}

// MARK: - The stats readout

/// The in-pane telemetry chip: five instrument-voice rows on the same dim material the stall caption uses,
/// touch-transparent.
///
/// The rows are ``GuiPaneReadout/statRows(_:)``'s, including the "—until measured" rule inside each, so
/// this view never decides what a missing reading looks like. The row COUNT is fixed there, so the labels
/// are made once and only their strings move — the stats mirror ticks about twice a second, and rebuilding
/// five labels at 2 Hz for the life of a stream is pure churn.
@MainActor
private final class GuiStatsReadout: UIView {
    private let column = UIStackView()
    private var labels: [UILabel] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // A readout over a surface that takes every touch. `isUserInteractionEnabled` covers the whole
        // subtree in one, which is what the Mac needs a `hitTest` override for.
        isUserInteractionEnabled = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        backgroundColor = Slate.Native.Surface.ground.slateScalingAlpha(Slate.Opacity.scrim)

        column.axis = .vertical
        column.spacing = Slate.Metric.space1
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: Slate.Metric.space2),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func present(_ telemetry: GuiStreamTelemetry) {
        let rows = GuiPaneReadout.statRows(telemetry)
        while labels.count < rows.count {
            let label = UILabel()
            labels.append(label)
            column.addArrangedSubview(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            label.attributedText = guiInstrumentString(rows[index], color: Slate.Native.Text.primary)
        }
    }
}

// MARK: - The stream-quality sheet

/// A live fps cap and bitrate ceiling for this session — `0` on either means auto, and the host's governor
/// and ABR run unclamped.
///
/// No Apply button: the override is cheap and reversible, so every change applies immediately. The model
/// re-asserts a remembered override into each fresh session, which is what makes a selection survive a
/// detach, a remount and a relaunch alike.
@MainActor
private final class GuiStreamTuneController: UIViewController {
    private let fpsChoice = UISegmentedControl(
        items: GuiPaneReadout.fpsChoices.map(GuiPaneReadout.fpsChoiceLabel),
    )
    private let bitrateChoice = UISegmentedControl(
        items: GuiPaneReadout.mbpsChoices.map(GuiPaneReadout.mbpsChoiceLabel),
    )
    private let onFps: (Int) -> Void
    private let onBitrate: (Int) -> Void

    init(fpsCap: Int, bitrateCapMbps: Int, onFps: @escaping (Int) -> Void, onBitrate: @escaping (Int) -> Void) {
        self.onFps = onFps
        self.onBitrate = onBitrate
        super.init(nibName: nil, bundle: nil)
        fpsChoice.selectedSegmentIndex = GuiPaneReadout.fpsChoices.firstIndex(of: fpsCap) ?? 0
        bitrateChoice.selectedSegmentIndex = GuiPaneReadout.mbpsChoices.firstIndex(of: bitrateCapMbps) ?? 0
        fpsChoice.addAction(UIAction { [weak self] _ in self?.fpsChanged() }, for: .valueChanged)
        bitrateChoice.addAction(UIAction { [weak self] _ in self?.bitrateChanged() }, for: .valueChanged)
        // The deleted half's `.frame(width: 300)`. A popover has no other width opinion, and the two
        // segmented controls are the widest things in it, so the number is what keeps the four bitrate
        // labels from compressing into unreadable stubs.
        preferredContentSize = CGSize(width: Self.popoverWidth, height: Self.popoverHeight)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private static let popoverWidth: CGFloat = 300
    /// Measured from the column below: four rungs of `space3`, two captions, two controls and the note.
    /// A popover needs a size before it lays out, so this is a floor rather than a solved height — the
    /// column's own constraints win once it is on screen.
    private static let popoverHeight: CGFloat = 260

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.face

        let title = UILabel()
        title.text = "Stream quality"
        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        title.textColor = Slate.Native.Text.primary

        let note = UILabel()
        note.text = "Applies live. Auto restores the adaptive governor/ABR."
        note.font = .systemFont(ofSize: Slate.Typeface.footnote)
        note.textColor = Slate.Native.Text.secondary
        note.numberOfLines = 0

        let column = UIStackView(arrangedSubviews: [
            title,
            field("FPS cap", fpsChoice),
            field("Bitrate ceiling", bitrateChoice),
            note,
        ])
        column.axis = .vertical
        column.spacing = Slate.Metric.space3
        column.alignment = .fill
        // `NSStackView.edgeInsets` in UIKit's spelling — a stack pads only when it is told the margins are
        // its own.
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space4, leading: Slate.Metric.space4,
            bottom: Slate.Metric.space4, trailing: Slate.Metric.space4,
        )
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
    }

    /// A captioned control — the deleted half's `VStack { Text(caption); Picker }` with `labelsHidden`.
    private func field(_ caption: String, _ control: UIView) -> UIView {
        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: Slate.Typeface.footnote)
        label.textColor = Slate.Native.Text.secondary
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = Slate.Metric.space1
        stack.alignment = .fill
        return stack
    }

    private func fpsChanged() {
        let index = fpsChoice.selectedSegmentIndex
        guard GuiPaneReadout.fpsChoices.indices.contains(index) else { return }
        onFps(GuiPaneReadout.fpsChoices[index])
    }

    private func bitrateChanged() {
        let index = bitrateChoice.selectedSegmentIndex
        guard GuiPaneReadout.mbpsChoices.indices.contains(index) else { return }
        onBitrate(GuiPaneReadout.mbpsChoices[index])
    }
}

// MARK: - The stall caption

/// "RECONNECTING · 12S" over a spinner — the stream is up but no frame has arrived.
///
/// A dim veil over the frame is deliberately avoided: the DRAIN happens on the stream's own layer (the
/// frozen last frame desaturates), so the material already says "this is the past". The caption carries
/// only what the material cannot — that recovery is running, and how old the frozen frame is. No button:
/// recovery is automatic underneath.
///
/// ⚠️ A `Task`, NOT A `Timer`, and that is docs/62 hazard 6 rather than taste. A repeating `Timer` is
/// retained by the run loop, so `[weak self]` stops it touching a dead view but does nothing to stop it
/// FIRING — the Mac half needs a self-invalidating handle to close that, and a `deinit` cannot help
/// because it is nonisolated. A `Task` cancelled from an explicit teardown has neither problem. The age is
/// RECOMPUTED rather than incremented, so a caption hidden and shown again is correct immediately instead
/// of resuming from a counter that stopped.
@MainActor
private final class StreamStallCaption: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private var since: Date?
    private var ticker: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        backgroundColor = Slate.Native.Surface.ground.slateScalingAlpha(Slate.Opacity.scrim)
        spinner.color = Slate.Native.Text.primary

        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.axis = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: Slate.Metric.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Show the caption counting from `since`, or hide it and stop the clock.
    ///
    /// The epoch is the model's ``RemoteWindowModel/streamStalledAt``, not the moment this was called, so a
    /// caption mounted late still reports the true age of the stall.
    func present(since epoch: Date?) {
        since = epoch
        guard epoch != nil else {
            teardown()
            return
        }
        spinner.startAnimating()
        refresh()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                guard let self else { return }
                refresh()
            }
        }
    }

    /// Leaving the window stops the clock — a stalled pane is the one state where a view is doing nothing
    /// and a per-second wakeup per hidden pane is pure cost.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { teardown() }
    }

    func teardown() {
        ticker?.cancel()
        ticker = nil
        spinner.stopAnimating()
    }

    private func refresh() {
        label.attributedText = guiInstrumentString(
            GuiPaneReadout.stallCaption(since: since, now: Date()),
            color: Slate.Native.Text.primary,
        )
    }
}

// MARK: - The paste result banner

/// "Typed 41, skipped 3 unmapped" — shown only when a clipboard paste dropped characters that have no
/// US-QWERTY mapping, so the user learns the paste was incomplete rather than silently wrong.
///
/// The whole pill is the dismiss target: this is the one decoration in the file a tap is *for*.
@MainActor
private final class PasteFeedbackBanner: UIControl {
    /// What this banner reports. Kept so the leaf can tell a NEW feedback from the one already on screen —
    /// the copy is baked in at init, so a change means a new banner rather than an update, and without
    /// this the leaf would rebuild it on every observation pass.
    let feedback: RemoteWindowModel.PasteFeedback

    private let onDismiss: () -> Void

    init(feedback: RemoteWindowModel.PasteFeedback, onDismiss: @escaping () -> Void) {
        self.feedback = feedback
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        backgroundColor = Slate.Native.Surface.face
        addAction(UIAction { [weak self] _ in self?.onDismiss() }, for: .touchUpInside)

        let glyph = UIImageView(image: UIImage(systemName: SFSymbol.exclamationmarkTriangle.rawValue))
        glyph.tintColor = Slate.Native.accent

        let text = UILabel()
        text.text = "Typed \(feedback.typed), skipped \(feedback.skipped) unmapped"
        text.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        text.textColor = Slate.Native.Text.primary

        let row = UIStackView(arrangedSubviews: [glyph, text])
        row.axis = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .center
        // The scenery must not take the tap the pill is FOR. A `UILabel` and a `UIImageView` are
        // non-interactive by default, so unlike AppKit — where `MacPassthroughStack` exists precisely
        // because an `NSTextField` hit-tests before its ancestor — the stack needs saying only once.
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: Slate.Metric.space3),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: Slate.Metric.space2),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        slateHelp("Dismiss")
        accessibilityValue = text.text
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        reink()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func reink() {
        layer.borderColor = Slate.Native.Line.divider.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - The file-drop highlight

/// An accent inset border while a file is dragged over a live desktop pane — the remote side will accept
/// the drop as an upload.
///
/// NO VEIL, deliberately: the stream stays fully visible and only the frame lights. A drop target that dims
/// what it is over is telling the user the content is unavailable, which is the opposite of true here.
///
/// The inset the deleted half spent as `.padding(space2)` is a child rim rather than a frame inset, so the
/// view can stay pinned to the leaf's four edges like every other overlay in the file.
@MainActor
private final class FileDropHighlight: UIView {
    /// Two points, matching the deleted half's `lineWidth: 2`. Heavier than a hairline on purpose — it has
    /// to read as a state over arbitrary video content, not as a rule.
    private static let rim: CGFloat = 2

    private let border = UIView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The drag is tracked by the leaf's own interaction, so this must not intercept it.
        isUserInteractionEnabled = false
        border.translatesAutoresizingMaskIntoConstraints = false
        border.layer.cornerRadius = Slate.Metric.radiusControl
        border.layer.cornerCurve = .continuous
        border.layer.borderWidth = Self.rim
        addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            border.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            trailingAnchor.constraint(equalTo: border.trailingAnchor, constant: Slate.Metric.space2),
            bottomAnchor.constraint(equalTo: border.bottomAnchor, constant: Slate.Metric.space2),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        reink()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ NO STROKE INSET. AppKit's `strokeBorder` draws INSIDE the path; a `CALayer`'s border does the
    /// same by definition, so the half-width correction a hand-drawn `NSBezierPath` needs has no
    /// counterpart and adding one would pull the frame half a rim off the corner radius.
    private func reink() {
        border.layer.borderColor = Slate.Native.accent.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - The upload stack

/// One row per in-flight or just-settled drag-drop upload: a state glyph, a name, and either a progress bar
/// or the failure reason.
///
/// The rows are rebuilt wholesale on each update rather than diffed. The list is bounded by what a user can
/// drag at once and each row is three views, so a diff would cost more to read than it saves — and a
/// rebuild cannot leave a stale row behind, which is the failure that actually matters for a readout whose
/// whole job is to say what is happening right now.
@MainActor
private final class FileUploadOverlay: UIView {
    /// The deleted half's `.frame(maxWidth: 320)` — a name is truncated in the MIDDLE rather than letting
    /// the stack grow across the pane, because the tail of a path is what identifies a file.
    private static let maxWidth: CGFloat = 320

    private let column = UIStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false // a readout over a surface that takes every touch
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        backgroundColor = Slate.Native.Surface.ground.slateScalingAlpha(Slate.Opacity.scrim)

        column.axis = .vertical
        column.spacing = Slate.Metric.space1
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: Slate.Metric.space2),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: Slate.Metric.space2),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func present(_ uploads: [FileUploadProgress]) {
        for stale in column.arrangedSubviews { stale.removeFromSuperview() }
        for upload in uploads { column.addArrangedSubview(row(upload)) }
    }

    private func row(_ upload: FileUploadProgress) -> UIView {
        let glyph = UIImageView(image: UIImage(
            systemName: GuiPaneReadout.uploadGlyph(upload.phase),
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .semibold,
            ),
        ))
        glyph.tintColor = tint(upload.phase)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let name = UILabel()
        name.text = upload.name
        name.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        name.textColor = Slate.Native.Text.primary
        name.lineBreakMode = .byTruncatingMiddle
        name.numberOfLines = 1

        let detail: UIView
        if upload.phase == .failed {
            let reason = UILabel()
            reason.text = upload.reason ?? "failed"
            reason.font = .systemFont(ofSize: Slate.Typeface.small)
            reason.textColor = Slate.Native.Text.secondary
            reason.lineBreakMode = .byTruncatingTail
            reason.numberOfLines = 1
            detail = reason
        } else {
            let bar = UIProgressView(progressViewStyle: .default)
            bar.progress = Float(upload.fraction)
            bar.progressTintColor = tint(upload.phase)
            detail = bar
        }

        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        // The deleted half's literal `2` between a name and its bar — tighter than `space1`, because the
        // two lines are ONE reading and a full rung would read as two.
        text.spacing = 2
        text.alignment = .fill

        let row = UIStackView(arrangedSubviews: [glyph, text])
        row.axis = .horizontal
        row.spacing = Slate.Metric.space2
        row.alignment = .center
        return row
    }

    /// The row's tone, looked up from the SEMANTIC ``GuiUploadTint``: the branch is
    /// ``GuiPaneReadout/uploadTint(_:)``'s and the token is this framework's. Only the part that could ever
    /// be wrong crosses — a colour cannot descend below the token floor.
    private func tint(_ phase: FileUploadProgress.Phase) -> UIColor {
        switch GuiPaneReadout.uploadTint(phase) {
        case .icon: Slate.Native.Text.icon
        case .accent: Slate.Native.accent
        }
    }
}

// MARK: - The reveal

/// The chrome's arrival and departure.
///
/// Everything here is pinned by constraints rather than arranged in a stack, so there is no reflow to
/// animate and no neighbour to slide past — the FADE is the whole transition, which is also what the
/// deleted half degraded to for an overlay whose neighbours do not move.
///
/// ⚠️ `isHidden` DOES NOT RIDE ALONG, unlike the Mac's twin, and the reason it does there does not hold
/// here. `MacGuiOverlayFade` hides because "a fully transparent view still hit-tests" — UIKit's hit-test
/// SKIPS a view at `alpha <= 0.01`, so a faded control bar already refuses the touch and the stream
/// underneath keeps it. What UIKit does NOT give free is the accessibility half: a faded overlay stays in
/// the tree, so a VoiceOver rotor would walk into a control bar nobody can see.
@MainActor
private enum GuiOverlayFade {
    static func set(_ view: UIView, shown: Bool) {
        view.accessibilityElementsHidden = !shown
        PaneFade.set(view, shown: shown)
    }

    static func retire(_ view: UIView) {
        view.accessibilityElementsHidden = true
        let curve = Slate.Motion.reveal
        CATransaction.begin()
        // The removal rides the SAME transaction as the fade, so there is no second clock to disagree
        // with the curve's duration — the layer-side twin of AppKit's `runAnimationGroup` completion.
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { view.removeFromSuperview() } }
        if view.window != nil {
            CATransaction.setAnimationDuration(curve.duration)
            CATransaction.setAnimationTimingFunction(curve.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        view.layer.opacity = 0
        CATransaction.commit()
    }
}

// MARK: - The instrument voice

/// The instrument run this file's two readouts print in — the UIKit twin of `MacCapsLabel`'s
/// `macInstrumentString`.
///
/// TRACKING IS AN ATTRIBUTE, NOT A PROPERTY: letter spacing reaches a `UILabel` only as `.kern` on the
/// string, which is why the text goes through an attributed run rather than straight onto `text`. Both the
/// face and the spacing are `Slate`'s; nothing here is this file's choice.
@MainActor
private func guiInstrumentString(_ text: String, color: UIColor) -> NSAttributedString {
    NSAttributedString(
        string: text,
        attributes: [
            .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium),
            .foregroundColor: color,
            .kern: Slate.Typeface.instrumentTracking,
        ],
    )
}
#endif
