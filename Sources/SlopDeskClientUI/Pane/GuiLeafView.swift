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
    /// "LOCK POSITION" button state — mirrored locally so the footer lock icon reflects on/off. The actual
    /// edge-pan freeze lives in the video view (via ``RemoteWindowModel/sendViewport(_:)``); this tracks it 1:1.
    @State private var panLocked = false

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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Inner padding so the remote surface isn't flush against pane edges / the split divider. The
                // Metal-hosting view is sized to this PADDED frame, so its pointer→host coordinate mapping
                // (relative to view bounds) stays consistent.
                .padding(Slate.Metric.space2)
            // WINDOW-PANE CONTROL BAR: window CONTROLS, kept out of the pane CONTENT and in the
            // footer — resize, lock-position (freeze edge-hover auto-pan), zoom in / out / reset — NOT a
            // status strip. Host + connection state live ONCE in the sidebar header, not duplicated here.
            // Only while live.
            if showControlBar {
                GuiPaneControlBar(model: model, store: store, panLocked: $panLocked)
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
            store.deactivateVideo(paneID)
        }
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
                // The live surface fills its (padded) leaf rect: the Metal-hosting view is sized to that rect,
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

/// The bottom CONTROL bar for a LIVE window pane: window controls kept OUT of the pane CONTENT —
/// "Resize…" (a numeric size popover rather than an in-content DRAG grip), a "lock position" toggle (freezes
/// edge-hover auto-pan), and zoom out / reset / in (client-side compositor zoom of the actual-size viewport). A
/// flat strip along the pane bottom, a single top hairline (never a floating card). Resize is gated on a live
/// host-resize sink (``RemoteWindowModel/canResizeWindow``, withheld while read-only); zoom/lock on a viewport
/// sink (``RemoteWindowModel/canControlViewport``, live even while read-only — pure client ops).
private struct GuiPaneControlBar: View {
    let model: RemoteWindowModel?
    /// The store — supplies the LOCAL clipboard (current + the recent-clips ring) for the paste menu.
    let store: WorkspaceStore
    /// Mirrors the pane's "lock position" state so the lock icon reflects on/off (the freeze itself lives in
    /// the video view; this toggles 1:1 with the `.toggleLock` command).
    @Binding var panLocked: Bool

    /// Whether the numeric "Resize…" size popover is open.
    @State private var showResizePopover = false

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            // PASTE: local-clipboard affordances — "Paste as Keystrokes" (types the CURRENT local clipboard
            // into the host window) + a "Clipboard Ring" submenu of recent clips (masked preview for secrets). A
            // footer MENU, not a surface context menu, which would steal the secondary-click the pane forwards to
            // the host window. Also via ⌥⌘V + the command palette.
            if let model {
                GuiPastePlateMenu(model: model, store: store)
            }
            if let model, model.canResizeWindow {
                SlatePlateButton(symbol: .arrowUpLeftAndArrowDownRight, help: "Resize remote window…") {
                    showResizePopover = true
                }
                .popover(isPresented: $showResizePopover, arrowEdge: .bottom) {
                    RemoteWindowSizePopover(model: model, isPresented: $showResizePopover)
                }
            }
            Spacer(minLength: Slate.Metric.space2)
            if let model, model.canControlViewport {
                SlatePlateButton(symbol: .minusMagnifyingglass, help: "Zoom out") { model.sendViewport(.zoomOut) }
                SlatePlateButton(symbol: .arrowCounterclockwise, help: "Actual size (reset zoom + position)") {
                    model.sendViewport(.reset)
                }
                SlatePlateButton(symbol: .plusMagnifyingglass, help: "Zoom in") { model.sendViewport(.zoomIn) }
                SlatePlateButton(
                    symbol: panLocked ? .lockFill : .lockOpen,
                    help: panLocked ? "Unlock viewport (resume edge-pan)" : "Lock viewport position (freeze edge-pan)",
                    tint: panLocked ? Slate.State.accent : Slate.Text.icon,
                ) {
                    panLocked.toggle()
                    model.sendViewport(.toggleLock)
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
    @State private var hovering = false

    /// The CURRENT local clipboard (live reader, works even with clipboard-history recording off).
    private var clipboard: String? { store.currentLocalClipboard() }
    /// Whether "Paste as Keystrokes" (types the current clipboard) is enabled right now.
    private var canPasteCurrent: Bool {
        ClipboardPasteMenu.canPaste(canPasteKeystrokes: model.canPasteKeystrokes, clipboard: clipboard)
    }

    var body: some View {
        Menu {
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
        } label: {
            Image(systemSymbol: .keyboard)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
                .background(
                    hovering ? Slate.State.hover : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusControl),
                )
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .slateHelp("Paste local clipboard into the remote window as keystrokes (⌥⌘V)")
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
