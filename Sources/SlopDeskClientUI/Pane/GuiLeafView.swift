// GuiLeafView — content of a video (PATH 2) pane leaf; the video parallel of
// ``TerminalLeafView``. Mounts the ``VideoWindowFactory`` seam for a `.remoteGUI` / `.systemDialog` pane,
// drives the cap-enforced activation lifecycle, else shows the in-pane picker / gated placeholder.
//
// THREE display states, decided by the PURE ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)``
// (headless-tested in `LiveVideoCapTests`):
//   • `.live`      → model has an active descriptor → mount `VideoWindowFactory.make(descriptor, context)`.
//   • `.entryForm` → no active stream and either unconfigured OR a cap slot free → the in-pane picker.
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
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct GuiLeafView: View {
    /// The live session backing this pane (its ``RemoteWindowModel``); `nil` shows only the placeholder.
    let live: LivePaneSession?
    /// Workspace focus → forwarded as `RemotePaneContext.isActive` so only the focused pane consumes
    /// pointer/keyboard input; a click on a background pane activates it via `onActivate`.
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots — renders the placeholder, never a
    /// live decode (no Metal/VT in an `ImageRenderer`).
    var staticMirror: Bool = false
    /// The store — the cap-admission authority (`activateVideo`/`deactivateVideo`) and the focus sink.
    let store: WorkspaceStore
    /// This pane's id — the activation + focus key.
    let paneID: PaneID
    /// Whether this video pane is ON-SCREEN (tab active AND not zoom-hidden). Under the keep-all-mounted
    /// invariant a hidden tab's leaf is NEVER unmounted, so `onDisappear` does not fire on a tab switch — this
    /// flag drives the activation lifecycle: a hidden pane releases its `liveVideoCap` slot
    /// + stops the UDP/VT/Metal pipeline, a visible one (re)requests a slot. Defaults `true` for static-mirror / preview.
    var isVisible: Bool = true
    /// Whether the in-pane STATS readout is showing (footer toggle). Per-pane view state — resets on
    /// remount, like the client-side zoom.
    @State private var showStats = false
    /// The pane's LIVE stream-settings selection (0 = auto) — mirrors what was last requested through
    /// ``RemoteWindowModel/applyStreamSettings(fpsCap:bitrateCeilingBps:)``. View state by design: a
    /// remount mints a NEW client session whose host state also resets to auto, so the two stay in step.
    @State private var fpsCapSelection = 0
    @State private var bitrateCapMbpsSelection = 0
    #if os(macOS)
    /// IMMERSIVE capture (system keys → host): the CGEventTap owner, engaged only while the toggle is on
    /// AND this pane can inject (live + not read-only). One controller per pane view.
    @State private var systemKeyCapture = SystemKeyCaptureController()
    /// Mirrors ``systemKeyCapture``'s engaged state for the footer toggle tint (the controller
    /// self-disengages on app-resign / the ⌃⌥⌘E escape chord — `onDisengage` keeps this in step).
    @State private var immersiveOn = false
    #endif

    /// The pane's remote-window model (picker/open/close/keyInjector). `nil` for a non-video handle.
    private var model: RemoteWindowModel? { live?.remoteWindow }

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
        VStack(spacing: 0) {
            // EDGE-TO-EDGE: no inner padding — every point of a video pane is remote pixels (a gutter
            // here is pure wasted stream area, unlike a terminal where the inset is a reading margin).
            // The Metal-hosting view is sized to the FULL leaf rect, so its pointer→host coordinate
            // mapping (relative to view bounds) stays consistent.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // WINDOW-PANE CONTROL BAR: window CONTROLS, kept out of the pane CONTENT and in the
            // footer — resize, lock-position (freeze edge-hover auto-pan), zoom in / out / reset — NOT a
            // status strip. Host + connection state live ONCE in the sidebar header, not duplicated here.
            // Only while live.
            if showControlBar {
                GuiPaneControlBar(
                    model: model, store: store, paneID: paneID,
                    showStats: $showStats,
                    fpsCapSelection: $fpsCapSelection,
                    bitrateCapMbpsSelection: $bitrateCapMbpsSelection,
                    immersiveOn: immersiveActive,
                    onToggleImmersive: { toggleImmersive() },
                )
            }
        }
        .background(NativePaneColor.terminalBackground)
        // PASTE-AS-KEYSTROKES RESULT BANNER: the model's transient "typed N, skipped M" feedback (set only
        // when some clipboard chars had no US-QWERTY mapping and were dropped) so the user learns a paste was
        // incomplete. Tap to dismiss; auto-clears on a timer. Never on the static-mirror path. Flat bottom pill.
        .overlay(alignment: .bottom) {
            if !staticMirror, let feedback = model?.pasteFeedback {
                PasteFeedbackBanner(feedback: feedback) { model?.dismissPasteFeedback() }
                    .padding(
                        .bottom,
                        showControlBar ? Slate.Metric.paneHeaderHeight + Slate.Metric.space2
                            : Slate.Metric.space2,
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Slate.Anim.reveal, value: model?.pasteFeedback)
        // The `🔒 READ ONLY ×` pill (``ReadOnlyPill``) so a read-only `.remoteGUI` /
        // `.systemDialog` pane is a VISUAL peer of a read-only terminal leaf (same top-trailing overlay/reveal as
        // ``TerminalLeafView``). Without it a locked remote window silently swallows clicks/keys with ZERO
        // feedback and no exit affordance. A video pane has no ``TerminalViewModel`` (no `exitReadOnly()`), so
        // `×` releases the lock via ``WorkspaceStore/setPaneReadOnly(_:_:)`` — the SAME source of truth the input
        // gate, View-menu item, and sidebar lock read. Gated by the pure
        // ``showReadOnlyPill(staticMirror:isReadOnly:)`` (never on the static-mirror path).
        .overlay(alignment: .topTrailing) {
            if Self.showReadOnlyPill(staticMirror: staticMirror, isReadOnly: store.isReadOnly(for: paneID)) {
                ReadOnlyPill(onDeactivate: { store.setPaneReadOnly(paneID, false) })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(Slate.Metric.space2)
            }
        }
        .animation(Slate.Anim.reveal, value: store.isReadOnly(for: paneID))
        // STATS READOUT (footer toggle): the client-local telemetry chip — instrument voice, top-leading
        // (top-trailing belongs to the read-only pill), hit-testing off so it never eats pane input.
        .overlay(alignment: .topLeading) {
            if showStats, !staticMirror, let model, model.active != nil {
                GuiStatsReadout(model: model)
                    .allowsHitTesting(false)
                    .padding(Slate.Metric.space2)
                    .transition(.opacity)
            }
        }
        .animation(Slate.Anim.reveal, value: showStats)
        // CAP ADMISSION: request a slot when ON-SCREEN, on appear AND whenever a sibling
        // frees one (`videoPromotionGeneration` bumps); `.task(id:)` cancels+restarts on either. Gated on
        // `isVisible` so a background-tab / zoom-hidden pane does NOT claim a `liveVideoCap` slot (else the
        // launch-time race where hidden tabs win the cap over the visible pane). NEVER calls `live.setVideoActive`
        // directly — the store enforces the cap + tearingDownVideo accounting. iOS resume re-activates
        // `wasVideoActiveBeforePause` in `LivePaneSession.resume`, so this is idempotent there.
        .task(id: activationKey) {
            guard !staticMirror, model != nil, isVisible else { return }
            _ = store.activateVideo(paneID)
        }
        // VISIBILITY-DRIVEN LIFECYCLE: under keep-all-mounted a hidden tab's leaf is never
        // unmounted, so `onDisappear` does NOT fire on a tab switch — driving (de)activation off `isVisible`
        // frees the slot + stops the decode pipeline off-screen and re-activates on return. (Zoom collapse too.)
        .onChange(of: isVisible) { _, nowVisible in
            guard !staticMirror, model != nil else { return }
            if nowVisible { _ = store.activateVideo(paneID) } else { store.deactivateVideo(paneID) }
        }
        // Belt-and-braces: a genuine unmount (pane close before reconcile teardown) also frees the slot.
        .onDisappear {
            guard !staticMirror else { return }
            #if os(macOS)
            systemKeyCapture.disengage() // an unmounted pane must never keep swallowing the keyboard
            #endif
            // RELOCATION GUARD (detach/reattach): this leaf unmounts while the pane is STILL desired —
            // in the tree (just reattached) or detached (just popped out) — and ANOTHER hosting root is
            // mounting the same PaneID. Deactivating here would close the model mid-handoff and race the
            // replacement view's fresh session/sinks. Only a pane gone from BOTH (a genuine close) frees
            // the slot; tab-hide never unmounts (keep-all-mounted), so the `isVisible` path is untouched.
            guard !store.tree.contains(paneID), !store.tree.isDetached(paneID) else { return }
            store.deactivateVideo(paneID)
        }
        #if os(macOS)
        // IMMERSIVE SAFETY: capture follows pane focus + injectability. Losing workspace focus (or the
        // satellite window's key state, which drives `isFocused` there) releases the keyboard; a read-only
        // flip withholds the sink → `canInjectSystemKeys` flips false → release too. The controller's own
        // app-resign observer + the ⌃⌥⌘E escape chord cover the rest; `onDisengage` keeps the toggle honest.
        .onChange(of: isFocused) { _, focused in
            if !focused { systemKeyCapture.disengage() }
        }
        .onChange(of: model?.canInjectSystemKeys ?? false) { _, can in
            if !can { systemKeyCapture.disengage() }
        }
        #endif
    }

    /// Whether immersive capture is live (macOS; constant `false` elsewhere — no CGEventTap).
    private var immersiveActive: Bool {
        #if os(macOS)
        immersiveOn
        #else
        false
        #endif
    }

    /// Flips immersive system-key capture for this pane. Engaging requires a live, writable pane
    /// (`canInjectSystemKeys`) and Accessibility trust — an untrusted first attempt surfaces the system
    /// prompt instead (the user flips the toggle again once granted). The forward closure re-reads the
    /// LIVE sink per event (mirrors `pasteAsKeystrokes`), so a read-only flip mid-capture stops
    /// forwarding instantly even before the auto-disengage lands.
    private func toggleImmersive() {
        #if os(macOS)
        if systemKeyCapture.isEngaged {
            systemKeyCapture.disengage() // onDisengage clears the mirror
            return
        }
        guard model?.canInjectSystemKeys == true else { return }
        guard SystemKeyCaptureController.isTrusted else {
            SystemKeyCaptureController.promptForTrust()
            return
        }
        systemKeyCapture.onDisengage = { immersiveOn = false }
        // The toggle click happened in this pane's window, so it IS the key window right now — arm the
        // controller's window-resign auto-disengage on it. Without this, another window of the SAME app
        // going key (Settings, a second satellite) keeps the app active and the pane focused, so neither
        // the app-resign observer nor the focus onChange would release the swallowed keyboard.
        immersiveOn = systemKeyCapture.engage(
            forward: { [weak model] keyCode, flags, isDown in
                model?.systemKeyInjector?(keyCode, flags, isDown)
            },
            keyWindow: NSApp.keyWindow,
        )
        #endif
    }

    /// The `.task` identity: re-run admission when THIS session changes (mount), a sibling frees a slot, OR
    /// visibility flips (so a pane returning to screen re-requests its slot immediately).
    private var activationKey: String {
        "\(live?.id.hashValue ?? 0):\(store.videoPromotionGeneration):\(isVisible ? 1 : 0)"
    }

    /// Whether the `🔒 READ ONLY ×` pill mounts — pane is read-only
    /// (``WorkspaceStore/isReadOnly(for:)``, the convergent set) AND NOT the static-mirror path (an
    /// `ImageRenderer` capture renders no live chrome). PURE so it is headless-testable without instantiating
    /// the view (hang-safety: no SCStream/VT/Metal/NSWindow). Mirrors ``TerminalLeafView``'s gate minus the
    /// vi/copy-mode exclusion — a video pane has no copy mode.
    static func showReadOnlyPill(staticMirror: Bool, isReadOnly: Bool) -> Bool {
        !staticMirror && isReadOnly
    }

    /// Whether the bottom CONTROL bar mounts — only while the LIVE surface is up (a live descriptor exists) and
    /// NOT on the static-mirror path. Its controls (resize / lock / zoom) are meaningful only against a live
    /// stream, so the picker / cap-gated states show no footer.
    private var showControlBar: Bool {
        !staticMirror && model?.active != nil
    }

    @ViewBuilder private var content: some View {
        if staticMirror {
            // STATIC snapshot: never a live decode — the placeholder mirror only.
            placeholder(.entryForm)
        } else {
            switch display {
            case .live:
                // The live surface fills the leaf rect edge-to-edge: the Metal-hosting view is sized to that rect,
                // so its tracking area + pointer→host coordinate mapping (relative to view bounds) stays correct.
                // The stream `.fit`-letterboxes inside; the remote window keeps its own size (no host-follow
                // resize — see `SlopDeskVideoClientSession.windowFollowsPane`). Resize lives in the bottom
                // CONTROL bar (`GuiPaneControlBar`), not an in-content corner grip.
                liveSurface
            case .entryForm:
                // A DESKTOP pane has no picker (its display target is fixed at mint) — the transient
                // pre-admission beat shows the calm placeholder, never the window-entry form.
                if let model, live?.kind != .desktop {
                    RemoteWindowPickerView(model: model, onActivate: { store.focusPaneTree(paneID) })
                } else {
                    placeholder(.entryForm)
                }
            case .gated:
                placeholder(.gated)
            }
        }
    }

    /// The live video surface — the gated `VideoWindowFactory` seam. The model already built the full
    /// descriptor (host + UDP ports from the app target) at `open()` time, so we pass `model.active` straight
    /// through. `onStreamNativeSize: nil` letterboxes a TILED leaf via `.fit`.
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
                    onNetworkStats: { [weak model] fps, fec, unrecovered, holdMs, depth in
                        model?.noteNetworkStats(
                            fps: fps, fecPerSec: fec, unrecoveredPerSec: unrecovered,
                            holdMs: holdMs, pacerDepth: depth,
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

    /// The native placeholder for the non-live states: the cap-gated "video paused" notice, or the bare
    /// idle mirror used on the static snapshot path.
    private func placeholder(_ state: RemoteGUIDisplay) -> some View {
        VStack(spacing: Slate.Metric.space3) {
            Image(systemSymbol: live?.kind == .systemDialog ? .lockShield : .display)
                .font(.system(size: Slate.Typeface.display, weight: .regular))
                .foregroundStyle(Slate.Text.secondary)
            Text(placeholderLabel(state))
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    private func placeholderLabel(_ state: RemoteGUIDisplay) -> String {
        if state == .gated { return "Video paused — too many live streams" }
        return switch live?.kind {
        case .systemDialog: "system dialog"
        case .desktop: "desktop"
        default: "remote window"
        }
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
                Text(caption(at: timeline.date))
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
                    .tracking(Slate.Typeface.instrumentTracking)
                    .foregroundStyle(Slate.Text.primary)
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(
                Slate.Surface.ground.opacity(0.88),
                in: .rect(cornerRadius: Slate.Metric.radiusSmall),
            )
        }
    }

    private func caption(at now: Date) -> String {
        guard let since else { return "RECONNECTING" }
        let age = max(0, Int(now.timeIntervalSince(since).rounded(.down)))
        return "RECONNECTING · \(age)S"
    }
}

/// The bottom CONTROL bar for a LIVE window pane: window controls kept OUT of the pane CONTENT. A flat
/// strip along the pane bottom, a single top hairline (never a floating card), split BY KIND: everything
/// LEFT of the spacer is a COMMAND (momentary — window verbs paste/resize/display/detach, then viewport
/// verbs fit/−/1×/+), everything RIGHT carries STATE (stats overlay, quality override, immersive,
/// viewport lock — the accent tint is a status light, and only the right side ever shows one). Resize is
/// gated on a live host-resize sink (``RemoteWindowModel/canResizeWindow``, withheld while read-only);
/// the viewport verbs + lock on ``RemoteWindowModel/canControlViewport`` (live even while read-only —
/// pure client ops).
private struct GuiPaneControlBar: View {
    let model: RemoteWindowModel?
    /// The store — supplies the LOCAL clipboard (current + the recent-clips ring) for the paste menu,
    /// and the detach/reattach ops.
    let store: WorkspaceStore
    /// This pane's id — the detach/reattach target.
    let paneID: PaneID
    /// The in-pane stats readout toggle (the chip renders in ``GuiLeafView``'s overlay).
    @Binding var showStats: Bool
    /// The live stream-settings selection (0 = auto), owned by the leaf so it outlives the popover.
    @Binding var fpsCapSelection: Int
    @Binding var bitrateCapMbpsSelection: Int
    /// Immersive system-key capture state + toggle (constant `false`/no-op off macOS).
    let immersiveOn: Bool
    let onToggleImmersive: () -> Void

    /// Whether the numeric "Resize…" size popover is open.
    @State private var showResizePopover = false
    /// Whether the stream-quality (fps cap / bitrate ceiling) popover is open.
    @State private var showTunePopover = false

    /// Whether this pane currently lives in a satellite window (drives detach ⇄ reattach flip).
    private var isDetached: Bool { store.tree.isDetached(paneID) }

    /// Whether the trailing MODE-STATE group (immersive + viewport lock) has anything to show — the
    /// group is gated as a whole so an all-absent state leaves no stray double gap in the bar's rhythm.
    private var showsModeToggles: Bool {
        var any = model?.canControlViewport == true
        #if os(macOS)
        any = any || immersiveOn || model?.canInjectSystemKeys == true
        #endif
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
                // clipboard into the host window) + a "Clipboard Ring" submenu of recent clips (masked
                // preview for secrets). A footer MENU, not a surface context menu, which would steal the
                // secondary-click the pane forwards to the host window. Also via ⌥⌘V + the command palette.
                if let model {
                    GuiPastePlateMenu(model: model, store: store)
                }
                if let model, model.canResizeWindow {
                    // The system window-resize glyph (dashed target square + arrow) — HOST window
                    // dimensions, deliberately NOT an arrows-only glyph so it can't be read as the
                    // client-side fit/zoom cluster.
                    SlatePlateButton(symbol: .squareResize, help: "Resize remote window…") {
                        showResizePopover = true
                    }
                    .popover(isPresented: $showResizePopover, arrowEdge: .bottom) {
                        RemoteWindowSizePopover(model: model, isPresented: $showResizePopover)
                    }
                }
                // DISPLAY SWITCHER (desktop panes): re-target the stream at another host display.
                if let model, model.desktopDisplayID != nil {
                    GuiDisplaySwitcherMenu(model: model)
                }
                // DETACH ⇄ REATTACH: pop this pane out into its own OS window (the live stream survives —
                // only the view remounts), or fold a satellite back into its tab. Mirrors ⌥⌘P / the menu.
                // The icon flips with placement but never latches an accent — a placement command, not a
                // mode. macOS-only: iOS has no satellite NSWindow.
                #if os(macOS)
                SlatePlateButton(
                    symbol: isDetached ? .macwindowAndPointerArrow : .macwindowOnRectangle,
                    help: isDetached ? "Reattach as a pane" : "Detach into its own window (⌥⌘P)",
                ) {
                    if isDetached { store.reattachPane(paneID) } else { store.detachPaneToWindow(paneID) }
                }
                #endif
            }
            // ── VIEWPORT COMMANDS (pure client compositor): fit, then the magnifier trio − / 1× / +.
            if let model, model.canControlViewport {
                HStack(spacing: Slate.Metric.space1) {
                    // FIT: shrink/grow the whole remote window to be fully visible inside the pane (client
                    // compositor zoom = min per-axis pane/window ratio) — the one-tap escape from an
                    // overflowing viewport. Arrows-INTO-a-rectangle: "fit content into the frame" (kept
                    // visually distinct from the host-window `squareResize` glyph above).
                    SlatePlateButton(symbol: .rectangleArrowtriangle2Inward, help: "Fit window to pane") {
                        model.sendViewport(.fitToPane)
                    }
                    SlatePlateButton(symbol: .minusMagnifyingglass, help: "Zoom out") {
                        model.sendViewport(.zoomOut)
                    }
                    SlatePlateButton(symbol: ._1Magnifyingglass, help: "Actual size (1× + re-anchor top-left)") {
                        model.sendViewport(.reset)
                    }
                    SlatePlateButton(symbol: .plusMagnifyingglass, help: "Zoom in") {
                        model.sendViewport(.zoomIn)
                    }
                }
            }
            Spacer(minLength: Slate.Metric.space2)
            // ── STREAM STATE: what the feed is doing — telemetry readout + quality override, both accent
            // while engaged.
            HStack(spacing: Slate.Metric.space1) {
                // STATS: toggle the client-local telemetry readout — informational, so it stays live even
                // on a read-only pane.
                if model != nil {
                    SlatePlateButton(
                        symbol: .chartBarXaxis,
                        help: showStats ? "Hide stream stats" : "Show stream stats",
                        tint: showStats ? Slate.State.accent : Slate.Text.icon,
                    ) { showStats.toggle() }
                }
                // STREAM QUALITY (fps cap / bitrate ceiling): live host-encode overrides — accent while a
                // non-auto override is applied. Gated on the settings sink (withheld while read-only).
                if let model, model.canAdjustStreamSettings {
                    SlatePlateButton(
                        symbol: .gaugeWithDotsNeedle67percent,
                        help: "Stream quality — fps cap / bitrate ceiling…",
                        tint: (fpsCapSelection != 0 || bitrateCapMbpsSelection != 0)
                            ? Slate.State.accent : Slate.Text.icon,
                    ) { showTunePopover = true }
                        .popover(isPresented: $showTunePopover, arrowEdge: .bottom) {
                            GuiStreamTunePopover(
                                model: model,
                                fpsCap: $fpsCapSelection,
                                bitrateCapMbps: $bitrateCapMbpsSelection,
                            )
                        }
                }
            }
            // ── MODE STATE: the two latched input/view modes, at the bar's outer edge where their accent
            // tints read as the pane's status lights.
            if showsModeToggles {
                HStack(spacing: Slate.Metric.space1) {
                    // IMMERSIVE (system keys → host): macOS CGEventTap capture; the engaged state also
                    // shows while the sink is withheld so the user can always turn it OFF. The ⌘ glyph —
                    // immersive routes the SYSTEM chords (⌘Tab, ⌘Space…) to the host.
                    #if os(macOS)
                    if let model, model.canInjectSystemKeys || immersiveOn {
                        SlatePlateButton(
                            symbol: .command,
                            help: immersiveOn
                                ? "Immersive on — system keys (⌘Tab, ⌘Space…) go to the host · ⌃⌥⌘E exits"
                                : "Immersive — send system keys (⌘Tab, ⌘Space…) to the host",
                            tint: immersiveOn ? Slate.State.accent : Slate.Text.icon,
                        ) { onToggleImmersive() }
                    }
                    #endif
                    // LOCK: the model owns the on/off state (``RemoteWindowModel/viewportLocked``) so this
                    // icon, the ⌥⌘L chord, and the menu row can never drift.
                    if let model, model.canControlViewport {
                        SlatePlateButton(
                            symbol: model.viewportLocked ? .lockFill : .lockOpen,
                            help: model.viewportLocked
                                ? "Unlock viewport (resume edge-pan) (⌥⌘L)"
                                : "Lock viewport position (freeze edge-pan) (⌥⌘L)",
                            tint: model.viewportLocked ? Slate.State.accent : Slate.Text.icon,
                        ) {
                            model.toggleViewportLock()
                        }
                    }
                }
            }
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
            row("\(model.streamFps.map(String.init) ?? "—") FPS · \(mbpsLabel) MBPS")
            row("RX \(model.statsFps.map { String(format: "%.0f", $0) } ?? "—") FPS · DEPTH "
                + "\(model.statsPacerDepth.map(String.init) ?? "—")")
            row("FEC \(perSecLabel(model.statsFecPerSec)) · LOST \(perSecLabel(model.statsUnrecoveredPerSec))")
            row("HOLD \(model.statsHoldMs.map(String.init) ?? "—") MS")
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            Slate.Surface.ground.opacity(0.88),
            in: .rect(cornerRadius: Slate.Metric.radiusSmall),
        )
    }

    private var mbpsLabel: String {
        guard let kbps = model.streamKbps else { return "—" }
        return String(format: "%.1f", Double(kbps) / 1000.0)
    }

    private func perSecLabel(_ value: Double?) -> String {
        guard let value else { return "—/S" }
        return String(format: "%.1f/S", value)
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
/// reversible); the host clamps on apply and the client session re-sends after any re-hello. Selections
/// reset to Auto with the session (a remount mints a new session whose host state is auto too).
private struct GuiStreamTunePopover: View {
    let model: RemoteWindowModel
    @Binding var fpsCap: Int
    @Binding var bitrateCapMbps: Int

    private static let fpsChoices = [0, 15, 30, 60]
    private static let mbpsChoices = [0, 5, 10, 20, 50]

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
                    ForEach(Self.fpsChoices, id: \.self) { fps in
                        Text(fps == 0 ? "Auto" : "\(fps)").tag(fps)
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
                    ForEach(Self.mbpsChoices, id: \.self) { mbps in
                        Text(mbps == 0 ? "Auto" : "\(mbps) Mb").tag(mbps)
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
        .onChange(of: fpsCap) { apply() }
        .onChange(of: bitrateCapMbps) { apply() }
    }

    private func apply() {
        model.applyStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCapMbps * 1_000_000)
    }
}

/// The desktop pane's DISPLAY SWITCHER: a footer menu of the host's online displays (fetched through the
/// session-less `listDisplays` discovery on mount) — picking one re-hellos the SAME pane at that display.
/// The current display is check-marked; a refresh row covers hot-plugged monitors.
private struct GuiDisplaySwitcherMenu: View {
    let model: RemoteWindowModel

    var body: some View {
        SlatePlateMenu(symbol: .display, help: "Switch host display") {
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

/// The numeric size popover — set the remote window's POINT size by typing width/height instead of dragging a
/// grip. Native SwiftUI controls: the fields pre-fill at the window's CURRENT size and cap at the host-reported
/// display MAX (``RemoteWindowModel/windowMaxPointSize``); "Maximize" jumps to that max (reachable because the
/// host re-anchors the window at its display origin). Apply requests an absolute host-window resize.
private struct RemoteWindowSizePopover: View {
    let model: RemoteWindowModel
    @Binding var isPresented: Bool

    @State private var width: Double = 0
    @State private var height: Double = 0

    /// UI floor (the session clamps to its own min too); fall back to a generous ceiling until the host
    /// reports the real display max.
    private static let minSide: Double = 240
    private static let fallbackMax: Double = 8192

    private var maxW: Double { Swift.max(
        Self.minSide,
        model.windowMaxPointSize.map { Double($0.width) } ?? Self.fallbackMax,
    ) }
    private var maxH: Double { Swift.max(
        Self.minSide,
        model.windowMaxPointSize.map { Double($0.height) } ?? Self.fallbackMax,
    ) }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            Text("Resize remote window")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            axisRow("Width", value: $width, range: Self.minSide...maxW)
            axisRow("Height", value: $height, range: Self.minSide...maxH)
            if let mx = model.windowMaxPointSize {
                Text("Display max \(Int(mx.width)) × \(Int(mx.height)) pt")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
            }
            HStack(spacing: Slate.Metric.space2) {
                if model.windowMaxPointSize != nil {
                    Button("Maximize") { width = maxW
                        height = maxH
                    }
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Slate.Metric.space4)
        .frame(width: 280)
        .onAppear {
            let cur = model.windowPointSize ?? CGSize(width: 1280, height: 800)
            width = clamp(Double(cur.width), Self.minSide, maxW)
            height = clamp(Double(cur.height), Self.minSide, maxH)
        }
    }

    private func axisRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(Slate.Text.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
            Stepper(label, value: value, in: range, step: 20)
                .labelsHidden()
            Text("pt").foregroundStyle(Slate.Text.secondary)
        }
        .font(.system(size: Slate.Typeface.body))
    }

    private func apply() {
        model.resizeWindow(toWidth: clamp(width, Self.minSide, maxW), height: clamp(height, Self.minSide, maxH))
        isPresented = false
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), Swift.max(lo, hi))
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
            help: "Paste local clipboard into the remote window as keystrokes (⌥⌘V)",
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
#endif
