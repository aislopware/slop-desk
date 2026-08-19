// GuiLeafView — content of a video (PATH 2) pane leaf; the video parallel of
// ``TerminalLeafView``. Mounts the ``VideoWindowFactory`` seam for a `.desktop` pane,
// drives the cap-enforced activation lifecycle, else shows the idle / gated placeholder.
//
// THREE display states, decided by the PURE ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)``
// (headless-tested in `LiveVideoCapTests`):
//   • `.live`      → model has an active descriptor → mount `VideoWindowFactory.make(descriptor, context)`.
//   • `.entryForm` → no active stream (pre-admission beat) → the calm idle placeholder.
//   • `.gated`     → configured but the 2-stream `liveVideoCap` is saturated → the cap placeholder.
//
// CAP LIFECYCLE: `.task` calls `store.activateVideo(paneID)` (NOT `live.setVideoActive` — that bypasses
// the cap + `tearingDownVideo` accounting); `.onDisappear` calls `store.deactivateVideo(paneID)`. Re-attempts
// admission when a sibling frees a slot via the `.task` keyed on `store.videoPromotionGeneration`.
//
// IDENTITY HAZARD: the pane is keyed `.id(PaneID)` by `SplitContainer` and the hosted Metal surface lives
// behind the factory's in-place `updateNSView` — never reconstruct the hosted view across panes (that resets
// `MetalLayerBackedView.isActive` mid-stream). `onStreamNativeSize: nil` letterboxes a TILED leaf via `.fit`
// instead of fighting the `SplitTreeRenderModel` split solver.
//
// SEAM discipline: NEVER imports `SlopDeskVideoClient`/VideoToolbox/Metal — only the seam types
// (`VideoWindowFactory`, `RemoteWindowDescriptor`, `RemotePaneContext`) cross. A headless `swift build`
// registers no factory, so `VideoWindowFactory.make` yields an `EmptyView`. SYSTEM/Slate tokens only.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct GuiLeafView: View {
    /// The live session backing this pane (its ``RemoteWindowModel``); `nil` shows only the placeholder.
    let live: LivePaneSession?
    /// Workspace focus → forwarded as `RemotePaneContext.isActive` so only the focused pane consumes
    /// pointer/keyboard input; a click on a background pane activates it via `onActivate`.
    let isFocused: Bool
    /// The store — the cap-admission authority (`activateVideo`/`deactivateVideo`) and the focus sink.
    let store: WorkspaceStore
    /// This pane's id — the activation + focus key.
    let paneID: PaneID
    /// Whether this video pane is ON-SCREEN (tab active AND not zoom-hidden). Under the keep-all-mounted
    /// invariant a hidden tab's leaf is NEVER unmounted, so `onDisappear` does not fire on a tab switch — this
    /// flag drives the activation lifecycle: a hidden pane releases its `liveVideoCap` slot
    /// + stops the UDP/VT/Metal pipeline, a visible one (re)requests a slot. Defaults `true` for a preview.
    var isVisible: Bool = true
    /// BACKGROUND INTERACTION (satellite windows): the user setting behind the background-pointer
    /// grant. Observed via `@Default` so a Settings flip re-renders the leaf and re-threads the seam
    /// context (no remount). Granted below ONLY for a detached pane — canvas panes keep
    /// click-to-activate.
    @Default(.satelliteBackgroundPointer) private var satelliteBackgroundPointer
    /// Whether the in-pane STATS readout is showing (footer toggle). Per-pane view state — resets on
    /// remount, like the client-side zoom.
    @State private var showStats = false
    /// Whether the window CONTROL BAR overlay is expanded. Collapsed by default — the pane's resting
    /// state is all stream, with the corner chip as the way in. Per-pane view state — resets on
    /// remount, like `showStats`.
    @State private var controlsExpanded = false
    /// Whether a file drag is hovering a live desktop pane (drives the drop-target highlight). Set only
    /// when the pane actually accepts uploads, so a window/dialog pane never flashes the border.
    @State private var isDropTargeted = false
    /// IMMERSIVE capture (system keys → host). Engaged while the toggle is ON — focus/app/window and
    /// read-only edges only SUSPEND swallowing (capture resumes by itself), so the toggle never
    /// silently flakes off. One per pane VIEW: the tap must die with its mount, while the toggle's
    /// on/off state lives on ``RemoteWindowModel/immersiveDesired`` so a detach/reattach remount
    /// re-engages instead of silently dropping the mode.
    ///
    /// UNGATED on purpose. The CGEventTap underneath is macOS-only and always will be, but that gate
    /// is spelled exactly once — inside ``PaneImmersiveCapture``, whose phone half is a no-op and
    /// whose ``PaneImmersiveCapture/isSupported`` is what keeps the footer from drawing a chip that
    /// would do nothing. Seven gates through this view were seven places to write an invisible
    /// `#else`.
    @State private var immersiveCapture = PaneImmersiveCapture()

    /// The pane's remote-window model (picker/open/close/keyInjector). `nil` for a non-video handle.
    private var model: RemoteWindowModel? { live?.remoteWindow }

    /// The stream-quality selections as write-through bindings onto the MODEL's remembered overrides
    /// (``RemoteWindowModel/streamFpsCap`` / ``streamBitrateCeilingBps``) — model-owned so the footer
    /// selection survives a detach/reattach remount and persists across relaunches. The popover edits
    /// one axis at a time; each write carries the other axis' current value (the sink is absolute).
    private var fpsCapSelection: Binding<Int> {
        Binding(
            get: { model?.streamFpsCap ?? 0 },
            set: { model?.applyStreamSettings(fpsCap: $0, bitrateCeilingBps: model?.streamBitrateCeilingBps ?? 0) },
        )
    }

    /// Mbps at the surface (the picker's unit), bps on the model/wire.
    private var bitrateCapMbpsSelection: Binding<Int> {
        Binding(
            get: { GuiPaneReadout.mbps(fromBps: model?.streamBitrateCeilingBps ?? 0) },
            set: {
                model?.applyStreamSettings(
                    fpsCap: model?.streamFpsCap ?? 0,
                    bitrateCeilingBps: GuiPaneReadout.bps(fromMbps: $0),
                )
            },
        )
    }

    /// The pure three-state display decision (live / entry-form / cap-gated), from the model's active
    /// descriptor + configured + free slot. Reads `store.videoPromotionGeneration` indirectly via
    /// `hasFreeVideoSlot`'s `registry` reads.
    private var display: RemoteGUIDisplay {
        guard let model else { return .entryForm }
        return RemoteGUIDisplay.resolve(
            admitted: model.active != nil,
            configured: model.canOpen,
            hasFreeSlot: store.hasFreeVideoSlot(for: paneID),
        )
    }

    var body: some View {
        // SPLIT IN TWO, and not for taste: as one chain this body defeated the type checker
        // ("unable to type-check this expression in reasonable time"). The cut is at the seam that was
        // already there — everything above DRAWS over the stream, everything below is LIFECYCLE (cap
        // admission, visibility, unmount, immersive capture, pointer). Neither half reads the other.
        chrome
            // CAP ADMISSION: request a slot when ON-SCREEN, on appear AND whenever a sibling
            // frees one (`videoPromotionGeneration` bumps); `.task(id:)` cancels+restarts on either. Gated on
            // `isVisible` so a background-tab / zoom-hidden pane does NOT claim a `liveVideoCap` slot (else the
            // launch-time race where hidden tabs win the cap over the visible pane). NEVER calls `live.setVideoActive`
            // directly — the store enforces the cap + tearingDownVideo accounting. iOS resume re-activates
            // `wasVideoActiveBeforePause` in `LivePaneSession.resume`, so this is idempotent there.
            .task(id: activationKey) {
                guard model != nil, isVisible else { return }
                _ = store.activateVideo(paneID)
                // A remount (detach/reattach) may find the model's sinks ALREADY live — then neither
                // `canInjectSystemKeys` nor `isFocused` fires an onChange edge, so the mount itself must
                // attempt the immersive re-engage.
                immersiveCapture.autoEngage(model: model, isFocused: isFocused)
            }
            // VISIBILITY-DRIVEN LIFECYCLE: under keep-all-mounted a hidden tab's leaf is never
            // unmounted, so `onDisappear` does NOT fire on a tab switch — driving (de)activation off `isVisible`
            // frees the slot + stops the decode pipeline off-screen and re-activates on return. (Zoom collapse too.)
            .onChange(of: isVisible) { _, nowVisible in
                guard model != nil else { return }
                if nowVisible { _ = store.activateVideo(paneID) } else { store.deactivateVideo(paneID) }
            }
            // Belt-and-braces: a genuine unmount (pane close before reconcile teardown) also frees the slot.
            .onDisappear {
                // An unmounted pane must never keep swallowing the keyboard — but an unmount must NOT
                // clear the model's immersive WISH either (a detach/reattach remount re-engages from it),
                // which is the distinction ``PaneImmersiveCapture/teardown()`` carries.
                immersiveCapture.teardown()
                // RELOCATION GUARD (detach/reattach): this leaf unmounts while the pane is STILL desired —
                // in the tree (just reattached) or detached (just popped out) — and ANOTHER hosting root is
                // mounting the same PaneID. Deactivating here would close the model mid-handoff and race the
                // replacement view's fresh session/sinks. Only a pane gone from BOTH (a genuine close) frees
                // the slot; tab-hide never unmounts (keep-all-mounted), so the `isVisible` path is untouched.
                guard !store.tree.contains(paneID), !store.tree.isDetached(paneID) else { return }
                store.deactivateVideo(paneID)
            }
            // IMMERSIVE SAFETY: capture follows pane focus + injectability — but as a SUSPENSION, never a
            // tear-down. Losing workspace focus (or the satellite window's key state, which drives `isFocused`
            // there) pauses swallowing; a read-only flip withholds the sink → `canInjectSystemKeys` flips false →
            // pause too. Either gate re-opening resumes capture by itself — the user's toggle survives (the old
            // disengage-on-every-edge design made it silently flake off on any popover/focus blip). The
            // capture's own app/window observers cover the app-level edges the same way; only the toggle,
            // the ⌃⌥⌘E escape chord, and unmount fully disengage.
            .onChange(of: isFocused) { _, focused in
                immersiveCapture.setSuspended(!focused || model?.canInjectSystemKeys != true)
                immersiveCapture.autoEngage(model: model, isFocused: focused)
            }
            .onChange(of: model?.canInjectSystemKeys ?? false) { _, can in
                immersiveCapture.setSuspended(!can || !isFocused)
                immersiveCapture.autoEngage(model: model, isFocused: isFocused)
            }
            // WISH SYNC: the model's EFFECTIVE wish (latched toggle OR the fullscreen auto-arm) can
            // change UNDER a mounted view — a re-target re-seeds the latch, and the window
            // entering/leaving native fullscreen flips the override.
            .onChange(of: model?.immersiveEffective ?? false) { _, wish in
                immersiveCapture.wishChanged(to: wish, model: model, isFocused: isFocused)
            }
    }

    /// Everything drawn OVER the stream: the control bar and its collapsed chip, the paste banner,
    /// the read-only pill, the stats readout, the upload destination and its progress stack.
    ///
    /// Pure decoration over ``content`` — it starts no task and watches no lifecycle edge, which is
    /// exactly why the cut is here and not at some arbitrary modifier count.
    private var chrome: some View {
        // EDGE-TO-EDGE: no inner padding — every point of a video pane is remote pixels (a gutter
        // here is pure wasted stream area, unlike a terminal where the inset is a reading margin).
        // The Metal-hosting view is sized to the FULL leaf rect, so its pointer→host coordinate
        // mapping (relative to view bounds) stays consistent.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.terminal)
            // WINDOW-PANE CONTROL BAR — COLLAPSED CHROME: the bar is an OVERLAY along the pane bottom,
            // hidden by default behind the corner chip below, so a video pane spends its whole leaf rect
            // on remote pixels (a resident footer would tax every pane ~28 pt of stream area forever for
            // controls used in bursts). Expanded it covers the bottom strip of the stream — a deliberate,
            // transient occlusion the user opted into. Only while live.
            .overlay(alignment: .bottom) {
                if showControlBar, controlsExpanded {
                    GuiPaneControlBar(
                        model: model, store: store, paneID: paneID,
                        showStats: $showStats,
                        fpsCapSelection: fpsCapSelection,
                        bitrateCapMbpsSelection: bitrateCapMbpsSelection,
                        immersiveOn: immersiveActive,
                        onToggleImmersive: { immersiveCapture.toggle(model: model) },
                        onCollapse: { controlsExpanded = false },
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // The COLLAPSED chip (Parsec-style): a single small plate, bottom-trailing (bottom-leading
            // belongs to the stall caption). Accent-tinted while any latched pane mode is engaged —
            // immersive / viewport lock / host audio / a stream override — so collapsing the bar never
            // hides a status light. A CLICK target, never hover-reveal: the bottom edge of a video pane
            // is the edge-hover auto-pan strip, so a hover-revealed bar would fight the pan gesture.
            .overlay(alignment: .bottomTrailing) {
                if showControlBar, !controlsExpanded {
                    collapsedControlsChip
                        .padding(Slate.Metric.space2)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.reveal, value: controlsExpanded)
            // PASTE-AS-KEYSTROKES RESULT BANNER: the model's transient "typed N, skipped M" feedback (set only
            // when some clipboard chars had no US-QWERTY mapping and were dropped) so the user learns a paste was
            // incomplete. Tap to dismiss; auto-clears on a timer. Flat bottom pill.
            .overlay(alignment: .bottom) {
                if let feedback = model?.pasteFeedback {
                    PasteFeedbackBanner(feedback: feedback) { model?.dismissPasteFeedback() }
                        .padding(
                            .bottom,
                            showControlBar && controlsExpanded
                                ? Slate.Metric.paneHeaderHeight + Slate.Metric.space2
                                : Slate.Metric.space2,
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Slate.Anim.reveal, value: model?.pasteFeedback)
            // The `🔒 READ ONLY ×` pill (``PaneStatusPillView``) so a read-only `.desktop`
            // pane is a VISUAL peer of a read-only terminal leaf (same top-trailing overlay/reveal as
            // ``TerminalLeafView``). Without it a locked remote window silently swallows clicks/keys with ZERO
            // feedback and no exit affordance. A video pane has no ``TerminalViewModel`` (no `exitReadOnly()`), so
            // `×` releases the lock via ``WorkspaceStore/setPaneReadOnly(_:_:)`` — the SAME source of truth the input
            // gate, View-menu item, and sidebar lock read. Gated by the pure
            // ``GuiPaneReadout/showsReadOnlyPill(isReadOnly:)``.
            .overlay(alignment: .topTrailing) {
                if GuiPaneReadout.showsReadOnlyPill(isReadOnly: store.isReadOnly(for: paneID)) {
                    PaneStatusPillView(pill: .readOnly, onDismiss: { store.setPaneReadOnly(paneID, false) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(Slate.Metric.space2)
                }
            }
            .animation(Slate.Anim.reveal, value: store.isReadOnly(for: paneID))
            // STATS READOUT (footer toggle): the client-local telemetry chip — instrument voice, top-leading
            // (top-trailing belongs to the read-only pill), hit-testing off so it never eats pane input.
            .overlay(alignment: .topLeading) {
                if showStats, let model, model.active != nil {
                    GuiStatsReadout(model: model)
                        .allowsHitTesting(false)
                        .padding(Slate.Metric.space2)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.reveal, value: showStats)
            // DRAG-DROP FILE UPLOAD (desktop panes): a file dragged from Finder — or, on iPad, from
            // Files.app or any app that vends a file URL — onto the remote desktop uploads over the
            // DEDICATED PATH-4 connection (never the terminal/video paths). The drop is accepted only
            // for a live desktop pane; a window/dialog pane rejects it (the existing
            // `PaneDropReceiver` path-inject still covers terminal panes elsewhere).
            //
            // NOT platform-gated, and it used to be. Nothing in the path is macOS's: the coordinator
            // is Foundation over the Network-backed transfer client, `.dropDestination` is SwiftUI's
            // on both, and the security-scoped grant an iOS drop needs is taken in
            // `FileUploadCoordinator` where it can outlive this callback. What differs is only what a
            // device can drag FROM — an iPhone has no cross-app drag, so the destination simply never
            // lights there; an iPad has, and now uploads.
            .dropDestination(for: URL.self) { urls, _ in
                GuiPaneUploads.handleDrop(urls, isUploadTarget: isDesktopUploadTarget, model: model)
            } isTargeted: { targeted in
                isDropTargeted = targeted && isDesktopUploadTarget
            }
            .overlay {
                if isDropTargeted {
                    FileDropHighlight()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.reveal, value: isDropTargeted)
            // UPLOAD PROGRESS: a compact stack of in-flight/just-settled uploads, top-center (clear of
            // the read-only pill top-trailing and the stats readout top-leading). Hit-testing off.
            .overlay(alignment: .top) {
                if let model, !model.activeUploads.isEmpty {
                    FileUploadOverlay(uploads: model.activeUploads)
                        .allowsHitTesting(false)
                        .padding(Slate.Metric.space2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Slate.Anim.reveal, value: model?.activeUploads ?? [])
    }

    /// Whether immersive capture is ON for the footer toggle/chip tint. This is the model's WISH —
    /// like a suspension, a not-yet-re-engaged remount still shows the latched tint so the mode never
    /// silently reads as off. Constant `false` on a half with no capture, because nothing there ever
    /// sets the wish and ``PaneImmersiveCapture/isSupported`` keeps the chip off the bar entirely.
    private var immersiveActive: Bool { model?.immersiveEffective == true }

    /// This pane's reading of ``GuiPaneReadout/isDesktopUploadTarget(kind:hasLiveDescriptor:)``.
    private var isDesktopUploadTarget: Bool {
        GuiPaneReadout.isDesktopUploadTarget(
            kind: store.tree.spec(for: paneID)?.kind,
            hasLiveDescriptor: model?.active != nil,
        )
    }

    /// This pane's reading of ``GuiPaneReadout/activationKey(paneHash:promotionGeneration:isVisible:)``.
    private var activationKey: String {
        GuiPaneReadout.activationKey(
            paneHash: live?.id.hashValue ?? 0,
            promotionGeneration: store.videoPromotionGeneration,
            isVisible: isVisible,
        )
    }

    /// This pane's reading of ``GuiPaneReadout/showsControlBar(hasLiveDescriptor:)``.
    private var showControlBar: Bool {
        GuiPaneReadout.showsControlBar(hasLiveDescriptor: model?.active != nil)
    }

    /// This pane's reading of ``GuiPaneReadout/hasLatchedMode(immersive:viewportLocked:audioEnabled:streamFpsCap:streamBitrateCeilingBps:)``
    /// — the tint the collapsed chip inherits, so no latched mode is ever invisible.
    private var hasLatchedMode: Bool {
        GuiPaneReadout.hasLatchedMode(
            immersive: immersiveActive,
            viewportLocked: model?.viewportLocked == true,
            audioEnabled: model?.audioStreamEnabled == true,
            streamFpsCap: model?.streamFpsCap ?? 0,
            streamBitrateCeilingBps: model?.streamBitrateCeilingBps ?? 0,
        )
    }

    /// The collapsed-chrome chip: one plate button on the same dim-ground material as the stall caption /
    /// stats readout, expanding the control bar. It costs one plate of remote pixels in the corner — the
    /// price of keeping the whole bar off-screen at rest.
    private var collapsedControlsChip: some View {
        SlatePlateButton(
            symbol: .ellipsis,
            help: GuiPaneReadout.Tooltip.expandControls,
            tint: hasLatchedMode ? Slate.State.accent : Slate.Text.icon,
        ) { controlsExpanded = true }
            .background(
                Slate.Surface.ground.opacity(Slate.Opacity.scrim),
                in: .rect(cornerRadius: Slate.Metric.radiusControl),
            )
    }

    @ViewBuilder private var content: some View {
        switch display {
        case .live:
            // The live surface fills the leaf rect edge-to-edge: the Metal-hosting view is sized to that rect,
            // so its tracking area + pointer→host coordinate mapping (relative to view bounds) stays correct.
            // The stream `.fit`-letterboxes inside; the remote window keeps its own size (no host-follow
            // resize — see `SlopDeskVideoClientSession.windowFollowsPane`). Resize lives in the bottom
            // CONTROL bar (`GuiPaneControlBar`), not an in-content corner grip.
            liveSurface
        case .entryForm:
            // Every video pane's target is fixed at mint (a display, or the dialog monitor's fresh
            // window id) — the transient pre-admission beat shows the calm placeholder.
            placeholder(.entryForm)
        case .gated:
            placeholder(.gated)
        }
    }

    /// The live video surface — the gated `VideoWindowFactory` seam. The model already built the full
    /// descriptor (host + UDP ports from the app target) at `open()` time, so we pass `model.active` straight
    /// through. `onStreamNativeSize: nil` letterboxes a TILED leaf via `.fit`.
    ///
    /// The seam's SwiftUI shape, and the phone's only one. The AppKit canvas takes the same renderer
    /// through `VideoWindowFactory.nativeShared`, which hands back the `NSView` over the `CAMetalLayer`
    /// directly (docs/56 stage F, risk 2). The per-render `RemotePaneContext` below is what SwiftUI
    /// re-evaluates on every pass; the AppKit half pushes the same three gates explicitly through
    /// `RemoteSurfaceHosting.setPaneGates(isActive:inputEnabled:backgroundPointer:)`, because it has no
    /// render pass to be re-run for it — which is exactly how a read-only flip could stop reaching the host
    /// on one canvas and not the other.
    ///
    /// READ-ONLY: the per-render context via ``RemotePaneContext/videoLeaf(...)`` from the pane's
    /// convergent read-only state (`store.isReadOnly(for:)`) — `inputEnabled = !readOnly` gates the app-target
    /// client's pointer/keycode forwarding, and the helper CLEARS the paste-as-keystrokes sink
    /// (`model.keyInjector = nil`) while read-only, so a locked window accepts no input via either path. The
    /// context is rebuilt every render, so a read-only flip re-evaluates both gates.
    @ViewBuilder private var liveSurface: some View {
        if let descriptor = model?.active {
            VideoWindowFactory.make(
                descriptor,
                context: RemotePaneContext.videoLeaf(
                    isActive: isFocused,
                    readOnly: store.isReadOnly(for: paneID),
                    // BACKGROUND INTERACTION: a DETACHED pane's satellite window keeps taking pointer
                    // input while not key (setting-gated); a canvas pane never does.
                    backgroundPointer: store.tree.isDetached(paneID) && satelliteBackgroundPointer,
                    onActivate: { store.focusPaneTree(paneID) },
                    onCanvasScroll: { _ in },
                    onStreamNativeSize: nil,
                    bindKeyInjector: { [weak model] sink in model?.keyInjector = sink },
                    bindResizeInjector: { [weak model] sink in model?.resizeInjector = sink },
                    // VIEWPORT CONTROLS: zoom / pan-lock — pure CLIENT compositor ops, so the seam
                    // binds this sink even on a read-only pane (unlike the host-affecting key/resize sinks).
                    bindViewportInjector: { [weak model] sink in model?.viewportInjector = sink },
                    // RELEASE STUCK INPUT: the palette's escape hatch — host input, so the seam binds
                    // nil while read-only (exactly like the key sink).
                    bindInputRelease: { [weak model] sink in model?.inputReleaseInjector = sink },
                    // LIVE STREAM SETTINGS (fps cap / bitrate ceiling): host encode behaviour — the
                    // seam binds nil while read-only (exactly like the resize sink).
                    bindStreamSettingsInjector: { [weak model] sink in model?.streamSettingsInjector = sink },
                    // HOST AUDIO (footer speaker): starts host-side audio capture+send — the seam
                    // binds nil while read-only (exactly like the stream-settings sink).
                    bindAudioInjector: { [weak model] sink in model?.audioInjector = sink },
                    // PRIVACY BLANK (desktop shield): host display-blank sink — the seam binds nil
                    // while read-only (exactly like the audio sink).
                    bindPrivacyInjector: { [weak model] sink in model?.privacyInjector = sink },
                    // SYSTEM-KEY INJECTOR (immersive capture): host key input — the seam binds nil
                    // while read-only (exactly like the paste-keystrokes sink).
                    bindSystemKeyInjector: { [weak model] sink in model?.systemKeyInjector = sink },
                    // HOST-WINDOW RESIZE: the live view pushes the window's current + max point sizes so the
                    // "Resize…" popover pre-fills + caps its fields (informational; not read-only-gated).
                    onWindowGeometry: { [weak model] cw, ch, mw, mh in
                        model?.noteWindowGeometry(currentW: cw, currentH: ch, maxW: mw, maxH: mh)
                    },
                    // CONNECTION STATS: the live view pushes the host-announced stream cadence + ~1 Hz
                    // client-measured payload bitrate so titlebar telemetry shows this pane's fps/Mbps
                    // (informational; not read-only-gated).
                    onStreamCadence: { [weak model] fps in model?.noteStreamFps(fps) },
                    onStreamBitrate: { [weak model] kbps in model?.noteStreamKbps(kbps) },
                    // NETWORK-STATS MIRROR (~2 Hz): feeds the toggleable in-pane stats readout
                    // (informational; not read-only-gated).
                    onNetworkStats: { [weak model] fps, fec, unrecovered, holdMs, depth, rtt, enc, dec in
                        model?.noteNetworkStats(
                            fps: fps, fecPerSec: fec, unrecoveredPerSec: unrecovered,
                            holdMs: holdMs, pacerDepth: depth,
                            rttMs: rtt, encodeMs: enc, decodeMs: dec,
                        )
                    },
                    // STALL SCRIM: the live view pushes the stream's stall flips (host silent ↔ traffic
                    // resumed) so the overlay below shows/clears "Reconnecting…" (informational).
                    onStreamStall: { [weak model] stalled in model?.noteStreamStalled(stalled) },
                    // TERMINAL REJECTION: the host refused the session (window gone / version skew) — tear
                    // down to the picker with an error, NEVER the auto-rebuild loop (a rejection re-hello
                    // would retry a doomed request forever).
                    onSessionRejected: { [weak model] in model?.noteSessionRejected() },
                ),
            )
            // STALL — MERIDIAN L1 "colour is live data, grayscale is the past": the DRAIN happens on the Metal
            // layer itself (`MetalLayerBackedView.applyStallDrain` desaturates the frozen last frame), so the
            // material says "this is the past" with no veil. This overlay adds only what the drain can't: a
            // corner caption with the frame's age. Hit-testing stays OFF — recovery is automatic underneath
            // (self-heal rebuild + hello retry).
            .overlay(alignment: .bottomLeading) {
                if model?.isStreamStalled == true {
                    StreamStallCaption(since: model?.streamStalledAt)
                        .allowsHitTesting(false)
                        .padding(Slate.Metric.space3)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.reveal, value: model?.isStreamStalled ?? false)
        }
    }

    /// The native placeholder for the non-live states: the cap-gated "video paused" notice, or the
    /// calm idle mirror of the pre-admission beat.
    private func placeholder(_ state: RemoteGUIDisplay) -> some View {
        VStack(spacing: Slate.Metric.space3) {
            Image(systemSymbol: .display)
                .font(.system(size: Slate.Typeface.display, weight: .regular))
                .foregroundStyle(Slate.Text.secondary)
            Text(GuiPaneReadout.placeholderLabel(state))
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.terminal)
    }
}

/// STALL CAPTION (MERIDIAN L1/L2): a dim-veil scrim over the frame is avoided because the drained frame IS the
/// "not live" signal, so this caption carries only what the material can't — that recovery is running and how
/// OLD the frozen frame is ("RECONNECTING · 12S", ticking). Instrument voice on a small dark chip pinned
/// bottom-leading; no card, no veil, deliberately no button (recovery is automatic underneath).
private struct StreamStallCaption: View {
    /// When the stall was detected (``RemoteWindowModel/streamStalledAt``) — the age counter's epoch.
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: Slate.Metric.space2) {
                ProgressView()
                    .controlSize(.mini)
                Text(GuiPaneReadout.stallCaption(since: since, now: timeline.date))
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
                    .tracking(Slate.Typeface.instrumentTracking)
                    .foregroundStyle(Slate.Text.primary)
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(
                Slate.Surface.ground.opacity(Slate.Opacity.scrim),
                in: .rect(cornerRadius: Slate.Metric.radiusSmall),
            )
        }
    }
}

/// The bottom CONTROL bar for a LIVE window pane: window controls kept OUT of the pane CONTENT. An
/// on-demand OVERLAY strip (collapsed to ``GuiLeafView``'s corner chip at rest — the leaf owns that
/// state), still a flat strip along the pane bottom, a single top hairline (never a floating card), split
/// BY KIND: everything
/// LEFT of the spacer is a COMMAND (momentary — window verbs paste/display/detach, then viewport
/// verbs fit/−/1×/+), everything RIGHT carries STATE (stats overlay, quality override, host audio,
/// immersive, viewport lock — the accent tint is a status light, and only the right side ever shows one).
/// The viewport verbs + lock gate on ``RemoteWindowModel/canControlViewport`` (live even while
/// read-only — pure client ops).
private struct GuiPaneControlBar: View {
    let model: RemoteWindowModel?
    /// The store — supplies the LOCAL clipboard (current + the recent-clips ring) for the paste menu,
    /// and the detach/reattach ops.
    let store: WorkspaceStore
    /// This pane's id — the detach/reattach target.
    let paneID: PaneID
    /// The in-pane stats readout toggle (the chip renders in ``GuiLeafView``'s overlay).
    @Binding var showStats: Bool
    /// The live stream-settings selection (0 = auto) — write-through bindings onto the MODEL's
    /// remembered overrides (see ``GuiLeafView/fpsCapSelection``), so they outlive the popover, the
    /// remount, and the relaunch alike.
    @Binding var fpsCapSelection: Int
    @Binding var bitrateCapMbpsSelection: Int
    /// Immersive system-key capture state + toggle (constant `false`/no-op off macOS).
    let immersiveOn: Bool
    let onToggleImmersive: () -> Void
    /// Folds the bar back into the leaf's corner chip (the leaf owns the expanded state).
    let onCollapse: () -> Void

    /// Whether the stream-quality (fps cap / bitrate ceiling) popover is open.
    @State private var showTunePopover = false

    /// The bar's copy, spelled once below the UI. Aliased only so a two-state tooltip fits on one
    /// line — the strings themselves live in ``GuiPaneReadout/Tooltip``.
    private typealias Tip = GuiPaneReadout.Tooltip

    /// Whether this pane currently lives in a satellite window (drives detach ⇄ reattach flip).
    private var isDetached: Bool { store.tree.isDetached(paneID) }

    /// Whether the trailing MODE-STATE group (immersive + viewport lock) has anything to show — the
    /// group is gated as a whole so an all-absent state leaves no stray double gap in the bar's rhythm.
    private var showsModeToggles: Bool {
        var any = model?.canControlViewport == true
        // The immersive chip only exists on a half that HAS a CGEventTap — capability as data
        // (``PaneImmersiveCapture/isSupported``), never a gate here. A chip drawn where the tap is a
        // no-op would be the listed-and-inert defect the palette and binding tables closed.
        if PaneImmersiveCapture.isSupported {
            any = any || immersiveOn || model?.canInjectSystemKeys == true
        }
        return any
    }

    var body: some View {
        // GROUPED BY KIND: LEFT of the spacer = COMMANDS (momentary — press, something happens, nothing
        // latches), RIGHT = STATE (toggles/overrides whose accent tint is a live status light). One rule
        // for the eye: an accent-tinted icon can only ever appear on the right. Groups are `space1`-tight
        // inside and `space3`-separated — grouping by RHYTHM, not divider ornament.
        HStack(spacing: Slate.Metric.space3) {
            // ── WINDOW COMMANDS: paste into it, resize it, re-target it, pop it out.
            HStack(spacing: Slate.Metric.space1) {
                // PASTE: local-clipboard affordances — "Paste as Keystrokes" (types the CURRENT local
                // clipboard into the host target) + a "Clipboard Ring" submenu of recent clips (masked
                // preview for secrets). A footer MENU, not a surface context menu, which would steal the
                // secondary-click the pane forwards to the host. Also via ⌥⌘V + the command palette.
                if let model {
                    GuiPastePlateMenu(model: model, store: store)
                }
                // DISPLAY SWITCHER (desktop panes): re-target the stream at another host display.
                if let model, model.desktopDisplayID != nil {
                    GuiDisplaySwitcherMenu(model: model)
                }
                // DETACH ⇄ REATTACH: pop this pane out into its own OS window (the live stream survives —
                // only the view remounts), or fold a satellite back into its tab. Mirrors ⌥⌘P / the menu.
                // The icon flips with placement but never latches an accent — a placement command, not a
                // mode. Present only where the satellite window exists — and that capability is DATA,
                // read from the SAME declaration (`slopdesk_workspace::binding_rows`) that decides
                // whether ⌥⌘P is bound and whether the palette lists the verb. This button is that
                // verb's fourth surface; a `#if` here would be a fourth place for the answer to drift.
                if BindingRowPlatform.lists("pane.detach") {
                    SlatePlateButton(
                        symbol: isDetached ? .macwindowAndPointerArrow : .macwindowOnRectangle,
                        help: isDetached ? Tip.reattach : Tip.detach,
                    ) {
                        if isDetached { store.reattachPane(paneID) } else { store.detachPaneToWindow(paneID) }
                    }
                }
            }
            // ── VIEWPORT COMMANDS (pure client compositor): fit, then the magnifier trio − / 1× / +.
            if let model, model.canControlViewport {
                // While the viewport is LOCKED these re-anchor the pan (fit/1×) or would otherwise read as
                // live controls the lock doesn't actually hold — disabling + dimming them (the same
                // `.disabled` + `.opacity(0.5)` pair `FontSettingsView`'s locked face-pickers use) is the
                // affordance that tells the user the lock button is the one to press first. The lock
                // button itself stays OUTSIDE this cluster (mode-state row below) and stays enabled.
                HStack(spacing: Slate.Metric.space1) {
                    // FIT: shrink/grow the whole remote window to be fully visible inside the pane (client
                    // compositor zoom = min per-axis pane/window ratio) — the one-tap escape from an
                    // overflowing viewport. Arrows-INTO-a-rectangle: "fit content into the frame" (kept
                    // visually distinct from the host-window `squareResize` glyph above).
                    SlatePlateButton(symbol: .rectangleArrowtriangle2Inward, help: Tip.fitToPane) {
                        model.sendViewport(.fitToPane)
                    }
                    SlatePlateButton(symbol: .minusMagnifyingglass, help: Tip.zoomOut) {
                        model.sendViewport(.zoomOut)
                    }
                    SlatePlateButton(symbol: ._1Magnifyingglass, help: Tip.actualSize) {
                        model.sendViewport(.reset)
                    }
                    SlatePlateButton(symbol: .plusMagnifyingglass, help: Tip.zoomIn) {
                        model.sendViewport(.zoomIn)
                    }
                }
                .disabled(model.viewportLocked)
                .opacity(model.viewportLocked ? 0.5 : 1)
            }
            Spacer(minLength: Slate.Metric.space2)
            // ── STREAM STATE: what the feed is doing — telemetry readout, quality override, host-audio
            // speaker, each accent while engaged.
            HStack(spacing: Slate.Metric.space1) {
                // STATS: toggle the client-local telemetry readout — informational, so it stays live even
                // on a read-only pane.
                if model != nil {
                    SlatePlateButton(
                        symbol: .chartBarXaxis,
                        help: showStats ? Tip.hideStats : Tip.showStats,
                        tint: showStats ? Slate.State.accent : Slate.Text.icon,
                    ) { showStats.toggle() }
                }
                // STREAM QUALITY (fps cap / bitrate ceiling): live host-encode overrides — accent while a
                // non-auto override is applied. Gated on the settings sink (withheld while read-only).
                if let model, model.canAdjustStreamSettings {
                    SlatePlateButton(
                        symbol: .gaugeWithDotsNeedle67percent,
                        help: Tip.streamQuality,
                        tint: (fpsCapSelection != 0 || bitrateCapMbpsSelection != 0)
                            ? Slate.State.accent : Slate.Text.icon,
                    ) { showTunePopover = true }
                        .popover(isPresented: $showTunePopover, arrowEdge: .bottom) {
                            GuiStreamTunePopover(
                                fpsCap: $fpsCapSelection,
                                bitrateCapMbps: $bitrateCapMbpsSelection,
                            )
                        }
                }
                // HOST AUDIO: the speaker toggle — accent while the host streams its app audio into this
                // pane. Stays visible while ON even when the sink is withheld (read-only), so the status
                // light never vanishes mid-stream; the verb itself is disabled then (mirrors the
                // immersive toggle's engaged-while-withheld visibility). Speaker family — no other glyph
                // in the bar uses it.
                if let model, model.canToggleAudio || model.audioStreamEnabled {
                    SlatePlateButton(
                        symbol: model.audioStreamEnabled ? .speakerWave2 : .speakerSlash,
                        help: model.audioStreamEnabled ? Tip.muteAudio : Tip.playAudio,
                        tint: model.audioStreamEnabled ? Slate.State.accent : Slate.Text.icon,
                    ) { model.applyAudioEnabled(!model.audioStreamEnabled) }
                        .disabled(!model.canToggleAudio)
                }
                // PRIVACY BLANK (DESKTOP panes only — the host verb is display-scoped): the shield
                // blacks the host's physical display + swallows local host input while ON, so a
                // bystander at the Mac sees nothing and cannot interfere. Accent while engaged;
                // stays visible ON even when withheld (read-only), like the speaker.
                if store.tree.spec(for: paneID)?.kind == .desktop, let model,
                   model.canTogglePrivacy || model.privacyEnabled
                {
                    SlatePlateButton(
                        symbol: model.privacyEnabled ? .eyeSlashFill : .eye,
                        help: model.privacyEnabled ? Tip.privacyOff : Tip.privacyOn,
                        tint: model.privacyEnabled ? Slate.State.accent : Slate.Text.icon,
                    ) { model.applyPrivacyEnabled(!model.privacyEnabled) }
                        .disabled(!model.canTogglePrivacy)
                }
            }
            // ── MODE STATE: the two latched input/view modes, at the bar's outer edge where their accent
            // tints read as the pane's status lights.
            if showsModeToggles {
                HStack(spacing: Slate.Metric.space1) {
                    // IMMERSIVE (system keys → host): macOS CGEventTap capture; the engaged state also
                    // shows while the sink is withheld so the user can always turn it OFF. The ⌘ glyph —
                    // immersive routes the SYSTEM chords (⌘Tab, ⌘Space…) to the host.
                    if PaneImmersiveCapture.isSupported, let model,
                       model.canInjectSystemKeys || immersiveOn
                    {
                        SlatePlateButton(
                            symbol: .command,
                            help: immersiveOn ? Tip.immersiveOn : Tip.immersiveOff,
                            tint: immersiveOn ? Slate.State.accent : Slate.Text.icon,
                        ) { onToggleImmersive() }
                    }
                    // LOCK: the model owns the on/off state (``RemoteWindowModel/viewportLocked``) so this
                    // icon, the ⌥⌘L chord, and the menu row can never drift.
                    if let model, model.canControlViewport {
                        SlatePlateButton(
                            symbol: model.viewportLocked ? .lockFill : .lockOpen,
                            help: model.viewportLocked ? Tip.unlockViewport : Tip.lockViewport,
                            tint: model.viewportLocked ? Slate.State.accent : Slate.Text.icon,
                        ) {
                            model.toggleViewportLock()
                        }
                    }
                }
            }
            // ── COLLAPSE: fold the bar back into the corner chip — the way OUT lives where the way IN
            // was, at the bar's outer edge. A momentary command, so it never carries a tint. The bar's
            // only chevron.
            SlatePlateButton(symbol: .chevronDown, help: Tip.collapseControls) { onCollapse() }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.paneHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(Slate.Surface.face) // FLAT: bar background == pane background
        .overlay(alignment: .top) {
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
        }
    }
}

/// The in-pane STATS readout (footer toggle): the client-local telemetry the session already computes —
/// host cadence + measured payload bitrate, received fps + pacer depth, FEC recoveries + unrecovered
/// losses per second, and the latest host-stamp hold. Instrument voice on a small dark chip (mirrors
/// ``StreamStallCaption``'s material), hit-testing off. Rows render "—" until their first reading lands.
private struct GuiStatsReadout: View {
    let model: RemoteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            // WHAT the five rows say — and the `—`-until-measured rule inside each — is
            // ``GuiPaneReadout/statRows(_:)``, over one ``GuiStreamTelemetry`` sample.
            // Every model property is still read HERE, so observation registers and the chip ticks with
            // the ~2 Hz stats mirror exactly as before.
            ForEach(Array(rows.enumerated()), id: \.offset) { _, text in
                row(text)
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            Slate.Surface.ground.opacity(Slate.Opacity.scrim),
            in: .rect(cornerRadius: Slate.Metric.radiusSmall),
        )
    }

    private var rows: [String] {
        GuiPaneReadout.statRows(GuiStreamTelemetry(
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
        ))
    }

    private func row(_ text: String) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
            .tracking(Slate.Typeface.instrumentTracking)
            .foregroundStyle(Slate.Text.primary)
    }
}

/// The stream-quality popover: a LIVE fps cap + bitrate ceiling for this session (0 = auto — the host's
/// governor/ABR run unclamped). Applies on every change (no Apply button — the override is cheap and
/// reversible); the bindings write through to ``RemoteWindowModel/applyStreamSettings(fpsCap:bitrateCeilingBps:)``,
/// the host clamps on apply, and the model re-asserts the remembered override into every fresh session
/// (remount / re-hello) — so a selection survives detach/reattach and a relaunch.
private struct GuiStreamTunePopover: View {
    @Binding var fpsCap: Int
    @Binding var bitrateCapMbps: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            Text("Stream quality")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text("FPS cap")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                Picker("FPS cap", selection: $fpsCap) {
                    ForEach(GuiPaneReadout.fpsChoices, id: \.self) { fps in
                        Text(GuiPaneReadout.fpsChoiceLabel(fps)).tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text("Bitrate ceiling")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                Picker("Bitrate ceiling", selection: $bitrateCapMbps) {
                    ForEach(GuiPaneReadout.mbpsChoices, id: \.self) { mbps in
                        Text(GuiPaneReadout.mbpsChoiceLabel(mbps)).tag(mbps)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Applies live. Auto restores the adaptive governor/ABR.")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
        }
        .padding(Slate.Metric.space4)
        .frame(width: 300)
    }
}

/// The desktop pane's DISPLAY SWITCHER: a footer menu of the host's online displays (fetched through the
/// session-less `listDisplays` discovery on mount) — picking one re-hellos the SAME pane at that display.
/// The current display is check-marked; a refresh row covers hot-plugged monitors.
private struct GuiDisplaySwitcherMenu: View {
    let model: RemoteWindowModel

    var body: some View {
        SlatePlateMenu(symbol: .display, help: GuiPaneReadout.Tooltip.displaySwitcher) {
            if model.availableDisplays.isEmpty {
                Button("No display list from host") {}.disabled(true)
            } else {
                ForEach(Array(model.availableDisplays.enumerated()), id: \.element.id) { index, display in
                    Button {
                        model.switchDisplay(to: display.displayID)
                    } label: {
                        if display.displayID == model.desktopDisplayID {
                            Label(display.displayLabel(ordinal: index + 1), systemSymbol: .checkmark)
                        } else {
                            Text(display.displayLabel(ordinal: index + 1))
                        }
                    }
                }
            }
            Divider()
            Button("Refresh Displays") {
                Task { await model.refreshDisplays() }
            }
        }
        .task { await model.refreshDisplays() }
    }
}

/// PASTE-AS-KEYSTROKES menu: the footer affordance making ``RemoteWindowModel/pasteAsKeystrokes(_:)`` +
/// the store's ``WorkspaceStore/clipboardRing`` REACHABLE in a remote-GUI pane — a plain ⌘V there forwards a
/// raw Cmd+V that pastes the HOST clipboard, so local text (e.g. a password for the auto-spawned SecurityAgent
/// dialog pane) could never reach a remote field. A native ``Menu``: "Paste as Keystrokes" types the CURRENT
/// local clipboard; the "Clipboard Ring" submenu lists recent clips with classifier-aware previews (secrets
/// masked). Enablement + previews from the headless ``ClipboardPasteMenu`` model. Disabled while the pane
/// can't type (not streaming / read-only). Mirrors the ⌥⌘V chord + palette command.
private struct GuiPastePlateMenu: View {
    let model: RemoteWindowModel
    let store: WorkspaceStore

    /// The CURRENT local clipboard (live reader, works even with clipboard-history recording off).
    private var clipboard: String? { store.currentLocalClipboard() }
    /// Whether "Paste as Keystrokes" (types the current clipboard) is enabled right now.
    private var canPasteCurrent: Bool {
        ClipboardPasteMenu.canPaste(canPasteKeystrokes: model.canPasteKeystrokes, clipboard: clipboard)
    }

    var body: some View {
        // Clipboard, not a keyboard: the verb is PASTE (the keystroke mechanics live in the
        // tooltip), and the immersive toggle needs the keyboard family to itself.
        SlatePlateMenu(
            symbol: .documentOnClipboard,
            help: GuiPaneReadout.Tooltip.paste,
        ) {
            Button("Paste as Keystrokes") {
                if let text = clipboard { model.pasteAsKeystrokes(text) }
            }
            .disabled(!canPasteCurrent)

            let rows = ClipboardPasteMenu.rows(store.clipboardRing)
            if rows.isEmpty {
                Button("No recent clips") {}.disabled(true)
            } else {
                Menu("Clipboard Ring") {
                    ForEach(rows) { row in
                        // The row label is the MASKED / truncated preview; the full clip (never shown) is typed.
                        Button(row.label) { model.pasteAsKeystrokes(row.text) }
                            .disabled(!model.canPasteKeystrokes)
                    }
                }
            }
        }
    }
}

/// The transient "typed N, skipped M" result banner for ``RemoteWindowModel/pasteAsKeystrokes(_:)`` —
/// shown only when some clipboard chars had no US-QWERTY mapping and were dropped, so the user learns a paste
/// was incomplete. Tap to dismiss (also auto-clears on the model's timer). A flat bottom pill.
private struct PasteFeedbackBanner: View {
    let feedback: RemoteWindowModel.PasteFeedback
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemSymbol: .exclamationmarkTriangle)
                    .foregroundStyle(Slate.State.accent)
                Text("Typed \(feedback.typed), skipped \(feedback.skipped) unmapped")
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
            }
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, Slate.Metric.space2)
            .background(Slate.Surface.face, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp("Dismiss")
    }
}

/// The drop-target highlight for a file dragged over a live desktop pane: an accent inset border so the
/// user sees the remote desktop will accept the drop (an upload over the dedicated channel). No veil —
/// the stream stays fully visible, only the frame lights.
private struct FileDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
            .strokeBorder(Slate.State.accent, lineWidth: 2)
            .padding(Slate.Metric.space2)
    }
}

/// The upload-progress stack (top-center): one row per in-flight or just-settled drag-drop upload, with
/// a name, a thin progress bar, and a trailing state glyph (↑ sending / ✓ done / ✗ failed). Instrument
/// voice on the same dim-ground material as the stats readout; the app coordinator dismisses each row a
/// moment after it settles.
private struct FileUploadOverlay: View {
    let uploads: [FileUploadProgress]

    var body: some View {
        VStack(spacing: Slate.Metric.space1) {
            ForEach(uploads) { upload in
                row(upload)
            }
        }
        .padding(Slate.Metric.space2)
        .background(
            Slate.Surface.ground.opacity(Slate.Opacity.scrim),
            in: .rect(cornerRadius: Slate.Metric.radiusSmall),
        )
        .frame(maxWidth: 320)
    }

    private func row(_ upload: FileUploadProgress) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemName: GuiPaneReadout.uploadGlyph(upload.phase))
                .foregroundStyle(tint(upload.phase))
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(upload.name)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if upload.phase == .failed {
                    Text(upload.reason ?? "failed")
                        .font(.system(size: Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                } else {
                    ProgressView(value: upload.fraction)
                        .progressViewStyle(.linear)
                        .tint(upload.phase == .completed ? Slate.State.accent : Slate.Text.icon)
                }
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The row's tone, looked up from the SEMANTIC ``GuiUploadTint``: the branch is
    /// ``GuiPaneReadout/uploadTint(_:)``'s, the token is this framework's. A `Color` cannot descend
    /// below the token floor, so only the part that could ever be wrong does.
    private func tint(_ phase: FileUploadProgress.Phase) -> Color {
        switch GuiPaneReadout.uploadTint(phase) {
        case .icon: Slate.Text.icon
        case .accent: Slate.State.accent
        }
    }
}
#endif
