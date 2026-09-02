// GuiLeafCore — the remote-window (PATH 2) pane leaf's LIFECYCLE, with no view type in it.
//
// `MacGuiLeafView` and `GuiLeafView` are the same leaf twice: they mount the ``VideoWindowFactory``
// seam, drive the cap-enforced activation lifecycle, and draw chrome over the stream. Only the LAST
// of those three is framework work. This type is the other two, held once — the seam's session, the
// descriptor it was built for, the cap admission, the three gates, the immersive tap and the
// per-pane view state that decides what the chrome says.
//
// WHAT CROSSES AND WHAT DOES NOT. Nothing here names `NSView` or `UIView`, and no `#if os(…)` picks
// between them. The leaf talks DOWN through ``GuiLeafHost`` — five verbs, each of which is the one
// sentence of AppKit or UIKit its shell has to write — and the shell talks UP through ``read()`` and
// ``apply(_:)``. The seam's own view never appears in a signature here either: ``GuiLeafHost`` is
// handed the `RemoteSurfaceHosting` and reads `surfaceView` off it in its own spelling.
//
// THE TRACKED READ STAYS IN THE SHELL, and deliberately. ``read()`` is written to be called from
// INSIDE a tracking block and ``apply(_:)`` from outside it, but which block that is — the Mac's
// ``ObservationFollow`` or the phone's hand-written `withObservationTracking` + generation guard —
// is docs/62 §3.1's business, mid-conversion, and a floor that picked one would be deciding it.
//
// ⚠️ THE ORDER IN ``apply(_:)`` IS LOAD-BEARING and is the same order both shells had: admission
// first (it can flip `model.active`, which the surface mounts on), then the pixels, then the gates,
// then — back in the shell — the chrome that describes them.

import Foundation
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The five sentences the shell owns

/// What a ``GuiLeafCore`` needs its shell to do, and nothing more: put a view in the tree, take it
/// out, show the placeholder, re-arm the tracked read, end it.
///
/// Held WEAKLY by the core (the shell owns the core, never the other way round), so every method
/// here must be safe to lose.
@MainActor
package protocol GuiLeafHost: AnyObject {
    /// Put the seam's view in the tree BELOW the chrome. A plain "add on top" would put an opaque
    /// stream layer over every overlay the leaf draws.
    func mountSurface(_ seam: RemoteSurfaceHosting)

    /// Take the seam's view back out. The session is torn down by the core; this is only the tree.
    func unmountSurface(_ seam: RemoteSurfaceHosting)

    /// Show the non-live state behind where the surface was.
    func presentPlaceholder(_ display: RemoteGUIDisplay)

    /// Re-arm the tracked read. Called by every core edge that can change what the leaf draws.
    func refollow()

    /// End the tracked read while the leaf lives on, waiting to be re-attached.
    func stopFollowing()
}

// MARK: - What the chrome is told

/// Everything drawn over the stream, read once per pass so the bar can never show half of one update
/// and half of the next.
///
/// `showStats` and `controlsExpanded` ride along rather than being read off the core: with them here
/// the shell's `applyChrome` is a pure function of this value, which is what makes it the ONE thing
/// the shell still has to write.
package struct GuiLeafChrome: Equatable {
    package var showControlBar = false
    package var hasLatchedMode = false
    /// The immersive light specifically — the latched-mode gate AND the model's own wish.
    package var immersiveOn = false
    package var readOnly = false
    package var stalled = false
    package var stalledAt: Date?
    package var telemetry = GuiStreamTelemetry()
    package var uploads: [FileUploadProgress] = []
    package var pasteFeedback: RemoteWindowModel.PasteFeedback?
    package var live = false
    package var showStats = false
    package var controlsExpanded = false
    /// Re-asserted every pass so the border can never be left lit by a drag the system cancelled.
    package var dropTargeted = false
    /// Whether this pane is a DESKTOP pane — the privacy shield's gate, and the ONE fact in this
    /// snapshot that cannot change for the life of the pane id. It rides here rather than being
    /// re-derived by each control bar because both bars were asking `TreeWorkspace.spec(for:)` — a
    /// full DFS over every session, tab and split node — once per plate sync, for an answer the core
    /// already had cached. See ``GuiLeafCore/isDesktopPane``.
    package var isDesktop = false

    package init() {}
}

/// What the GUI control bar hands back UP, on either shell.
///
/// Three callbacks, not three overrides: the bar decides nothing about them — folding, the stats chip
/// and immersive capture are all the LEAF's state — so the bar's whole part is to say that a plate was
/// pressed. A protocol rather than four assignments per shell because a forgotten wiring is a DEAD
/// BUTTON with nothing red anywhere: it compiles, it draws, it does nothing when pressed, and only a
/// person tapping it finds out. That is exactly the failure a shared floor is for.
@MainActor
package protocol GuiLeafControlBarWiring: AnyObject {
    var onCollapse: () -> Void { get set }
    var onToggleStats: () -> Void { get set }
    var onToggleImmersive: () -> Void { get set }
}

/// The corner chip the bar folds into — the other half of the same latch.
@MainActor
package protocol GuiLeafCollapsedChipWiring: AnyObject {
    var onExpand: () -> Void { get set }
}

/// One pass of the tracked read: the four edges the deleted SwiftUI half gave an `.onChange` each,
/// plus the chrome.
package struct GuiLeafReading {
    package var display = RemoteGUIDisplay.entryForm
    package var activationKey = ""
    package var injectable = false
    package var immersiveWish = false
    package var chrome = GuiLeafChrome()

    package init() {}
}

// MARK: - The leaf, minus its pixels

@MainActor
package final class GuiLeafCore {
    // MARK: What the leaf was handed

    package let store: WorkspaceStore
    package let paneID: PaneID
    private var live: LivePaneSession?
    private var isFocused: Bool
    /// Whether this pane is ON-SCREEN (tab active AND not zoom-hidden). Under keep-all-mounted a
    /// hidden tab's leaf is never unmounted, so this — not the view's window — is what frees the
    /// `liveVideoCap` slot and stops the UDP/VT/Metal pipeline off-screen.
    private var isVisible: Bool

    package var model: RemoteWindowModel? { live?.remoteWindow }

    private weak var host: GuiLeafHost?

    // MARK: The session

    private var seam: RemoteSurfaceHosting?
    /// What ``mountSurface()`` last built for, so a pass that changed nothing about the descriptor
    /// does not tear a live decode stack down and rebuild it.
    private var mountedDescriptor: RemoteWindowDescriptor?

    /// The tap must die with this MOUNT, while the on/off WISH lives on the model — which is what
    /// makes a detach/reattach re-engage instead of silently dropping the mode.
    private let immersiveCapture = PaneImmersiveCapture()

    // MARK: Per-pane view state — resets on remount, exactly like the `@State` it replaces

    private var showStats = false
    private var controlsExpanded = false
    private var isDropTargeted = false
    private var cachedPaneKind: PaneKind?

    // MARK: The live reads

    private var isWired = false
    /// `desktop.satellite-background-pointer`, re-read by ``read()`` off ``ConfigRevision`` — it
    /// re-pushes the GATE rather than remounting, which is the whole point of `setPaneGates`.
    private var satelliteBackgroundPointer = SettingsKey.satelliteBackgroundPointerEnabled

    /// Last values of the four things the deleted half gave an `.onChange` each. Optional-less:
    /// every one has a well-defined false/empty reading for a pane with no model.
    private var lastActivationKey: String?
    private var lastInjectable = false
    private var lastImmersiveWish = false

    // MARK: - Life

    package init(live: LivePaneSession?, isFocused: Bool, isVisible: Bool, store: WorkspaceStore, paneID: PaneID) {
        self.live = live
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.store = store
        self.paneID = paneID
    }

    /// Adopt the shell and go live. Split from ``init(live:isFocused:isVisible:store:paneID:)``
    /// because the shell cannot hand over `self` until its own `super.init` has run.
    package func start(host: GuiLeafHost) {
        self.host = host
        mountSurface()
        attach()
    }

    /// The leaf entered the tree, or came back to it. Idempotent and re-installable.
    package func attach() {
        guard !isWired else { return }
        isWired = true
        host?.refollow()
    }

    /// The leaf left the tree. THE CAP SLOT IS NOT FREED HERE, because a leaf can leave the tree
    /// without its pane going away — a split rearrange re-parents it, and detach/reattach mounts
    /// another hosting root for the SAME PaneID while this one is still coming down. Deactivating
    /// here would close the model mid-handoff and race the replacement's fresh session.
    package func detach() {
        guard isWired else { return }
        isWired = false
        host?.stopFollowing()
    }

    /// The pane is closed for good.
    ///
    /// The immersive tap comes down FIRST and unconditionally: an unmounted pane that keeps
    /// swallowing the keyboard has no owner left to disengage it.
    /// ``PaneImmersiveCapture/teardown()`` is the verb that drops the tap WITHOUT clearing the
    /// model's wish, so a reattach still re-engages.
    package func teardown() {
        detach()
        immersiveCapture.teardown()
        dropSeam()
        mountedDescriptor = nil
        // THE RELOCATION GUARD. Gone from the tree AND not detached is the only reading of "closed".
        guard !store.tree.contains(paneID), !store.tree.isDetached(paneID) else { return }
        store.deactivateVideo(paneID)
    }

    // MARK: - What the mounter pushes

    package func setLive(_ live: LivePaneSession?) {
        guard live !== self.live else { return }
        self.live = live
        mountSurface()
        refollowIfWired()
    }

    package func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        push()
        // IMMERSIVE SAFETY: focus drives a SUSPENSION, never a tear-down. Losing focus pauses
        // swallowing; regaining it resumes by itself, so the user's toggle survives a popover blip.
        immersiveCapture.setSuspended(!isFocused || model?.canInjectSystemKeys != true)
        immersiveCapture.autoEngage(model: model, isFocused: isFocused)
        refollowIfWired()
    }

    package func setVisible(_ isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
        refollowIfWired()
    }

    // MARK: - What the chrome pushes back

    /// Point the bar and its chip at this core. All four in one call, so the set cannot go half-wired.
    package func wireControls(bar: GuiLeafControlBarWiring, chip: GuiLeafCollapsedChipWiring) {
        bar.onCollapse = { [weak self] in self?.setControlsExpanded(false) }
        bar.onToggleStats = { [weak self] in self?.toggleStats() }
        bar.onToggleImmersive = { [weak self] in self?.toggleImmersive() }
        chip.onExpand = { [weak self] in self?.setControlsExpanded(true) }
    }

    package func setControlsExpanded(_ expanded: Bool) {
        guard expanded != controlsExpanded else { return }
        controlsExpanded = expanded
        refollowIfWired()
    }

    package func toggleStats() {
        showStats.toggle()
        refollowIfWired()
    }

    package func toggleImmersive() {
        immersiveCapture.toggle(model: model)
    }

    private func refollowIfWired() {
        guard isWired else { return }
        host?.refollow()
    }

    // MARK: - The session

    /// The video seam — the production renderer if the app registered a native factory, else the
    /// placeholder. Neither UI target ever imports Metal or VideoToolbox: they only call the factory.
    package func mountSurface() {
        let descriptor = model?.active
        // A REBUILD IS A TEARDOWN. The hosting view owns UDP sockets, a decoder and a display link,
        // so remounting for an unchanged descriptor would reset a live stream mid-frame — the
        // identity hazard spelled as "never reconstruct the hosted view across panes".
        if descriptor == mountedDescriptor, seam != nil || descriptor == nil { return }
        dropSeam()
        mountedDescriptor = descriptor

        guard let descriptor else { return }
        guard let made = VideoWindowFactory.make(descriptor, context: paneContext()) else { return }
        seam = made
        host?.mountSurface(made)
    }

    private func unmountSurface(_ display: RemoteGUIDisplay) {
        dropSeam()
        mountedDescriptor = nil
        host?.presentPlaceholder(display)
    }

    /// End the client session AND take its view out of the tree. Removing the view is not enough on
    /// its own: the session owns UDP sockets, a decoder and a display link.
    private func dropSeam() {
        guard let seam else { return }
        seam.detachSurface()
        self.seam = nil
        host?.unmountSurface(seam)
    }

    /// The per-render context SwiftUI rebuilt on every pass. Built here at MOUNT, and its three
    /// gates re-pushed by ``push()`` afterwards — the sinks below are bound once because they are
    /// bound to the model, and it is `setPaneGates` that republishes them on a read-only flip.
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
            // VIEWPORT CONTROLS: zoom / pan-lock — pure CLIENT compositor ops, so the seam binds this
            // sink even on a read-only pane (unlike the host-affecting key/resize sinks).
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
            onSessionRejected: { [weak model] refusal in model?.noteSessionRejected(refusal) },
        )
    }

    /// THE ONLY WAY A READ-ONLY LOCK REACHES THE HOST on an imperative canvas. SwiftUI got this from
    /// being re-run; here it is a call, and every edge that can change one of the three gates makes
    /// it.
    private func push() {
        seam?.setPaneGates(
            isActive: isFocused,
            inputEnabled: !store.isReadOnly(for: paneID),
            backgroundPointer: store.tree.isDetached(paneID) && satelliteBackgroundPointer,
        )
    }

    // MARK: - The pass

    /// ONE read of everything the leaf draws, activates on, or triggers an immersive edge from.
    ///
    /// ⚠️ CALL THIS INSIDE THE TRACKING BLOCK AND NOWHERE ELSE. A read that lands outside it does not
    /// invalidate, which is the bug class docs/62 §3.1 names and the reason the value is RETURNED
    /// rather than applied: everything below is a read, and ``apply(_:)`` is everything that is not.
    package func read() -> GuiLeafReading {
        // The config-file edge — `AppConfig` is a plain locked global, so the setting below is
        // observable only through the revision, and the read must stay INSIDE the tracking block or
        // the leaf silently unsubscribes. See ``ConfigRevision``.
        _ = ConfigRevision.shared.generation
        // Stored rather than returned: ``readChrome()`` and ``push()`` both read the gate off `self`,
        // so it must land before the reads below rather than travel in the value.
        satelliteBackgroundPointer = SettingsKey.satelliteBackgroundPointerEnabled
        var reading = GuiLeafReading()
        reading.display = display
        reading.activationKey = GuiPaneReadout.activationKey(
            paneHash: live?.id.hashValue ?? 0,
            promotionGeneration: store.videoPromotionGeneration,
            isVisible: isVisible,
        )
        reading.injectable = model?.canInjectSystemKeys ?? false
        reading.immersiveWish = model?.immersiveEffective ?? false
        reading.chrome = readChrome()
        return reading
    }

    /// Everything ``read()`` is not, applied OUTSIDE the tracking block. The shell paints
    /// `reading.chrome` afterwards — that, and only that, is what stayed in AppKit and UIKit.
    package func apply(_ reading: GuiLeafReading) {
        // ORDER MATTERS. Admission first (it can flip `model.active`, which the surface mounts on),
        // then the pixels, then the gates.
        applyActivation(key: reading.activationKey)
        if reading.display == .live { mountSurface() } else { unmountSurface(reading.display) }
        push()
        applyImmersiveEdges(injectable: reading.injectable, wish: reading.immersiveWish)
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

    /// CAP ADMISSION. The SwiftUI half's `.task(id: activationKey)`: request a slot when on-screen,
    /// on mount AND whenever a sibling frees one (`videoPromotionGeneration` bumps, which changes the
    /// key). NEVER calls `live.setVideoActive` directly — the store enforces the cap and the
    /// `tearingDownVideo` accounting. iOS resume re-activates `wasVideoActiveBeforePause` in
    /// `LivePaneSession.resume`, so this is idempotent there.
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

    /// The two `.onChange`s that are about the tap rather than the drawing.
    ///
    /// A read-only flip withholds the system-key sink, which is a SUSPENSION exactly like losing
    /// focus; the wish edge is a re-target or a fullscreen flip changing the wish under a mounted
    /// view, which must move the tap both ways.
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

    private func readChrome() -> GuiLeafChrome {
        var chrome = GuiLeafChrome()
        chrome.showStats = showStats
        chrome.controlsExpanded = controlsExpanded
        chrome.dropTargeted = isDropTargeted
        chrome.isDesktop = isDesktopPane
        chrome.readOnly = GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: paneID))
        guard let model else { return chrome }
        chrome.live = model.active != nil
        chrome.showControlBar = GuiPaneReadout.showsControlBar(hasLiveDescriptor: chrome.live)
        chrome.hasLatchedMode = GuiPaneReadout.hasLatchedMode(
            // The model's WISH, not the tap's state: a suspended or not-yet-re-engaged mode must
            // still show its light, or the chip claims a mode is off while it is only paused.
            immersive: model.immersiveEffective,
            viewportLocked: model.viewportLocked,
            audioEnabled: model.audioStreamEnabled,
            streamFpsCap: model.streamFpsCap,
            streamBitrateCeilingBps: model.streamBitrateCeilingBps,
        )
        chrome.immersiveOn = chrome.hasLatchedMode && model.immersiveEffective
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

    // MARK: - The file drop (PATH 4)

    /// Whether this pane accepts an upload at all, from the same pure gate the SwiftUI half read: a
    /// LIVE DESKTOP pane only. A window or dialog pane must never flash the border for a drag it will
    /// refuse.
    package var isDesktopUploadTarget: Bool {
        GuiPaneReadout.isDesktopUploadTarget(
            kind: paneKind, hasLiveDescriptor: model?.active != nil,
        )
    }

    /// The new highlight state when it CHANGED, `nil` when nothing moved — so the shell fades the
    /// border only on a real edge, and the decision of WHETHER stays out of the drawing.
    package func dropTargeted(_ targeted: Bool) -> Bool? {
        let wanted = targeted && isDesktopUploadTarget
        guard wanted != isDropTargeted else { return nil }
        isDropTargeted = wanted
        return wanted
    }

    /// Hand the dropped file urls to ``GuiPaneUploads/handleDrop(_:isUploadTarget:model:)``, which
    /// owns the routing and the dedicated PATH-4 connection. The `Bool` is what AppKit's
    /// `performDragOperation` must return; UIKit's async drop has nobody to tell and discards it.
    @discardableResult
    package func handleDrop(_ urls: [URL]) -> Bool {
        GuiPaneUploads.handleDrop(urls, isUploadTarget: isDesktopUploadTarget, model: model)
    }

    /// The privacy shield's gate, from the cache rather than from a fresh walk.
    package var isDesktopPane: Bool { paneKind == .desktop }

    /// This pane's KIND, resolved once and held.
    ///
    /// ⚠️ Only the KIND is cached; the LIVENESS half of ``isDesktopUploadTarget`` stays a fresh read,
    /// because a stream can go down mid-drag and a pane that stops being able to receive the file has
    /// to stop saying `.copy`. A kind cannot: it is fixed for the life of the pane id.
    ///
    /// The reason it may not be re-read is the drag-update callback — AppKit's `draggingUpdated(_:)`
    /// fires on EVERY pointer move for the whole duration of a drag and UIKit's `sessionDidUpdate(_:)`
    /// fires continuously while the session is inside the view, including when the finger stops dead
    /// — while `TreeWorkspace.spec(for:)` is a full DFS over every session, every tab and every split
    /// node. Hovering a file over a video pane was re-walking the entire workspace per frame. `nil` is
    /// deliberately NOT cached, so a spec that has not landed yet is asked for again rather than
    /// latched absent.
    private var paneKind: PaneKind? {
        if let cachedPaneKind { return cachedPaneKind }
        let kind = store.tree.spec(for: paneID)?.kind
        cachedPaneKind = kind
        return kind
    }
}
