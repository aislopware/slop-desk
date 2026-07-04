// GuiLeafView — the content of a video (PATH 2) pane leaf (WS-A / A1–A4). The video parallel of
// ``TerminalLeafView``: it closes the `PaneContainer` TODO(L5) gap by mounting the real
// ``VideoWindowFactory`` seam for a `.remoteGUI` / `.systemDialog` pane, driving the cap-enforced
// activation lifecycle, and showing the in-pane picker / gated placeholder otherwise.
//
// The display has THREE states, decided by the PURE ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)``
// (headless-tested in `LiveVideoCapTests`):
//   • `.live`      → the model has an active descriptor → mount `VideoWindowFactory.make(descriptor, context)`.
//   • `.entryForm` → no active stream and either unconfigured OR a cap slot is free → the in-pane picker (A3).
//   • `.gated`     → configured but the 2-stream `liveVideoCap` is saturated → the cap placeholder.
//
// CAP LIFECYCLE (A2): `.task` calls `store.activateVideo(paneID)` (NOT `live.setVideoActive` — that bypasses
// the cap + `tearingDownVideo` accounting); `.onDisappear` calls `store.deactivateVideo(paneID)` so a
// tab-switch frees the slot. The leaf re-attempts admission when a sibling frees a slot by re-running the
// `.task` keyed on `store.videoPromotionGeneration`.
//
// IDENTITY HAZARD: the whole pane is keyed `.id(PaneID)` by `SplitContainer`, and the hosted Metal surface
// lives behind the factory's in-place `updateNSView` — this view never reconstructs the hosted view across
// panes (that would reset `MetalLayerBackedView.isActive` mid-stream). `onStreamNativeSize: nil` makes a
// TILED leaf letterbox via `.fit` instead of fighting the `SplitTreeRenderModel` split solver.
//
// SEAM discipline: this library NEVER imports `AislopdeskVideoClient`/VideoToolbox/Metal — only the seam
// types (`VideoWindowFactory`, `RemoteWindowDescriptor`, `RemotePaneContext`) cross. A headless `swift build`
// registers no factory, so `VideoWindowFactory.make` yields an `EmptyView`. NATIVE chrome (system semantic
// colors / text styles / materials — the 2026-07-03 native-chrome migration); the video canvas fabric stays
// theme-driven (`NativePaneColor`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct GuiLeafView: View {
    /// The live session backing this pane (its ``RemoteWindowModel``). `nil` (no live handle yet) shows
    /// the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → forwarded as `RemotePaneContext.isActive` so only the focused pane consumes
    /// pointer/keyboard input (A4); a click on a background pane activates it via `onActivate`.
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots — renders the placeholder, never a
    /// live decode (no Metal/VT in an `ImageRenderer`).
    var staticMirror: Bool = false
    /// The store — the cap-admission authority (`activateVideo`/`deactivateVideo`) and the focus sink.
    let store: WorkspaceStore
    /// This pane's id — the activation + focus key.
    let paneID: PaneID
    /// Whether this video pane is currently ON-SCREEN (its tab is active AND it is not zoom-hidden). Under the
    /// keep-all-mounted invariant a hidden tab's leaf is NEVER unmounted, so `onDisappear` does not fire on a
    /// tab switch — this visibility flag is what actually drives the activation lifecycle (A2/R-lifecycle #2):
    /// a pane that goes hidden releases its `liveVideoCap` slot + stops the UDP/VT/Metal pipeline, and one that
    /// becomes visible (re)requests a slot. Defaults to `true` for the static-mirror / preview paths.
    var isVisible: Bool = true
    /// "LOCK POSITION" button state — mirrored locally so the footer lock icon reflects on/off. The actual
    /// edge-pan freeze lives in the video view (toggled via ``RemoteWindowModel/sendViewport(_:)``); this stays
    /// in sync 1:1 with the toggle and resets with the pane.
    @State private var panLocked = false

    /// The pane's remote-window model (picker/open/close/keyInjector). `nil` for a non-video handle.
    private var model: RemoteWindowModel? { live?.remoteWindow }

    /// The pure three-state display decision (live / entry-form / cap-gated), driven by the model's
    /// active descriptor + whether it is configured + whether a cap slot is free. Reads
    /// `store.videoPromotionGeneration` indirectly via `hasFreeVideoSlot`'s `registry` reads.
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
                // Inner padding so the remote surface doesn't sit flush against the pane edges / the split
                // divider (issue: "thêm padding vào các pane"). The Metal-hosting view is sized to this PADDED
                // frame, so its pointer→host coordinate mapping (relative to the view bounds) stays consistent.
                .padding(8)
            // WINDOW-PANE CONTROL BAR (issue 5): the bottom bar carries the window CONTROLS — resize (moved out
            // of the pane CONTENT into the footer), lock-position (freeze the edge-hover auto-pan), and zoom
            // in / out / reset — NOT a status strip. Host + connection state now live ONCE in the sidebar
            // header, so a video pane no longer duplicates them here. Shown only while the live surface is up.
            if showControlBar {
                GuiPaneControlBar(model: model, store: store, panLocked: $panLocked)
            }
        }
        .background(NativePaneColor.terminalBackground)
        // PASTE-AS-KEYSTROKES RESULT BANNER (C7): surface the model's transient "typed N, skipped M" feedback
        // (set only when some clipboard characters had no US-QWERTY mapping and were dropped) so the user
        // learns a paste was incomplete instead of silently losing them. Tap to dismiss; auto-clears on a
        // timer. Never on the static-mirror snapshot path. A tiny bottom material chip.
        .overlay(alignment: .bottom) {
            if !staticMirror, let feedback = model?.pasteFeedback {
                PasteFeedbackBanner(feedback: feedback) { model?.dismissPasteFeedback() }
                    .padding(.bottom, showControlBar ? 28 + 8 : 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model?.pasteFeedback)
        // E21 WI-3 (F3): the `🔒 READ ONLY ×` pill (E17 ``ReadOnlyPill``) so a read-only `.remoteGUI` /
        // `.systemDialog` pane is a VISUAL peer of a read-only terminal leaf — same top-trailing overlay,
        // alignment, padding, and reveal animation as ``TerminalLeafView``. Without it a locked remote window
        // silently swallows clicks/keys (the WI-3 input gate is solid) with ZERO in-pane feedback and no exit
        // affordance. A video pane has no ``TerminalViewModel`` (so no `exitReadOnly()`), so `×` releases the
        // lock through the store's convergent set directly via ``WorkspaceStore/setPaneReadOnly(_:_:)`` — the
        // SAME source of truth the input gate, the View-menu item, and the sidebar lock read. Gated by the pure
        // ``showReadOnlyPill(staticMirror:isReadOnly:)`` (never on the static-mirror snapshot path).
        .overlay(alignment: .topTrailing) {
            if Self.showReadOnlyPill(staticMirror: staticMirror, isReadOnly: store.isReadOnly(for: paneID)) {
                ReadOnlyPill(onDeactivate: { store.setPaneReadOnly(paneID, false) })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(8)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.isReadOnly(for: paneID))
        // CAP ADMISSION (A2/R-lifecycle #2): request a slot when this pane is ON-SCREEN, on appear AND whenever
        // a sibling frees one (`videoPromotionGeneration` bumps). `.task(id:)` cancels+restarts on either
        // change. Gated on `isVisible` so a background-tab / zoom-hidden pane does NOT claim a `liveVideoCap`
        // slot (the launch-time race where hidden tabs win the cap over the visible pane). NEVER calls
        // `live.setVideoActive` directly — the store enforces the cap + tearingDownVideo accounting. iOS resume
        // re-activates `wasVideoActiveBeforePause` inside `LivePaneSession.resume`, so this is idempotent there.
        .task(id: activationKey) {
            guard !staticMirror, model != nil, isVisible else { return }
            _ = store.activateVideo(paneID)
        }
        // VISIBILITY-DRIVEN LIFECYCLE (R-lifecycle #2): under keep-all-mounted a hidden tab's leaf is never
        // unmounted, so `onDisappear` does NOT fire on a tab switch — driving (de)activation off `isVisible` is
        // what frees the slot + stops the decode pipeline when this pane goes off-screen and re-activates it on
        // return. (Zoom collapse hides a sibling the same way.)
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
    /// this pane's visibility flips (so a pane returning to screen re-requests its slot immediately).
    private var activationKey: String {
        "\(live?.id.hashValue ?? 0):\(store.videoPromotionGeneration):\(isVisible ? 1 : 0)"
    }

    /// E21 WI-3 (F3): whether the `🔒 READ ONLY ×` pill mounts over this video pane — the pane is read-only
    /// (``WorkspaceStore/isReadOnly(for:)``, the convergent set) AND this is NOT the static-mirror snapshot
    /// path (an `ImageRenderer` capture renders no live chrome). PURE so it is headless-testable without
    /// instantiating the view (hang-safety: no SCStream/VT/Metal/NSWindow). Mirrors ``TerminalLeafView``'s
    /// `showReadOnlyPill` gate minus the vi/copy-mode exclusion — a video pane has no copy mode.
    static func showReadOnlyPill(staticMirror: Bool, isReadOnly: Bool) -> Bool {
        !staticMirror && isReadOnly
    }

    /// Whether the bottom CONTROL bar mounts on this video pane — only while the LIVE surface is up (a live
    /// descriptor exists) and NOT on the static-mirror snapshot path. The bar's controls (resize / lock / zoom)
    /// are meaningful only against a live stream, so the picker / cap-gated placeholder states show no footer.
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
                // The live surface fills its (now padded) leaf rect: the Metal-hosting view is sized to that
                // rect, so its tracking area + pointer→host coordinate mapping (relative to the view bounds)
                // stays correct across the whole surface. The stream `.fit`-letterboxes inside; the remote
                // window keeps its own size (no host-follow resize — see
                // `AislopdeskVideoClientSession.windowFollowsPane`). The resize affordance is no longer an
                // in-content corner grip — it moved to the bottom CONTROL bar (`GuiPaneControlBar`).
                liveSurface
            case .entryForm:
                if let model {
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
    /// descriptor (host + UDP ports resolved from the app target) at `open()` time, so we pass
    /// `model.active` straight through. `onStreamNativeSize: nil` letterboxes a TILED leaf via `.fit`.
    ///
    /// READ-ONLY (E21 WI-3): the per-render context is derived through ``RemotePaneContext/videoLeaf(...)``
    /// from the pane's convergent read-only state (`store.isReadOnly(for:)`) — `inputEnabled = !readOnly`
    /// gates the app-target client's pointer/keycode forwarding, and the helper CLEARS the paste-as-keystrokes
    /// sink (binds `model.keyInjector = nil`) while read-only, so a locked remote window accepts no input via
    /// either path. The context is rebuilt on every render, so a read-only flip re-evaluates both gates.
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
                    // VIEWPORT CONTROLS (issue 5): zoom / pan-lock — pure CLIENT compositor ops, so the seam
                    // binds this sink even on a read-only pane (unlike the host-affecting key/resize sinks).
                    bindViewportInjector: { [weak model] sink in model?.viewportInjector = sink },
                    // RELEASE STUCK INPUT (C5): the palette's escape hatch — host input, so the seam binds
                    // nil while read-only (exactly like the key sink).
                    bindInputRelease: { [weak model] sink in model?.inputReleaseInjector = sink },
                    // HOST-WINDOW RESIZE: the live view pushes the window's current + max point sizes so the
                    // "Resize…" popover pre-fills + caps its fields (informational; not read-only-gated).
                    onWindowGeometry: { [weak model] cw, ch, mw, mh in
                        model?.noteWindowGeometry(currentW: cw, currentH: ch, maxW: mw, maxH: mh)
                    },
                    // CONNECTION STATS: the live view pushes the host-announced stream cadence so the sidebar's
                    // Connection section shows this pane's FPS row (informational; not read-only-gated).
                    onStreamCadence: { [weak model] fps in model?.noteStreamFps(fps) },
                    // STALL SCRIM: the live view pushes the stream's stall flips (host silent ↔ traffic
                    // resumed) so the overlay below shows/clears "Reconnecting…" (informational).
                    onStreamStall: { [weak model] stalled in model?.noteStreamStalled(stalled) },
                ),
            )
            // STALL SCRIM (the reconnect-wedge residual): while the host is silent past the stall threshold
            // the pane would otherwise look healthy-but-dead (a frozen last frame that swallows clicks).
            // A translucent veil + spinner card says "the client noticed; recovery is automatic" (the
            // self-heal rebuild + hello retry run underneath). Hit-testing stays OFF — purely visual, so
            // any interaction still reaches the surface (harmless while the host is dark).
            .overlay {
                if model?.isStreamStalled == true {
                    StreamStallScrim()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model?.isStreamStalled ?? false)
        }
    }

    /// The native placeholder for the non-live states: the cap-gated "video paused" notice, or the bare
    /// idle mirror used on the static snapshot path.
    private func placeholder(_ state: RemoteGUIDisplay) -> some View {
        VStack(spacing: 12) {
            Image(systemSymbol: live?.kind == .systemDialog ? .lockShield : .display)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text(placeholderLabel(state))
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    private func placeholderLabel(_ state: RemoteGUIDisplay) -> String {
        if state == .gated { return "Video paused — too many live streams" }
        return live?.kind == .systemDialog ? "system dialog" : "remote window"
    }
}

/// STALL SCRIM (2026-07-03): the "Reconnecting…" veil over a live video surface whose host has gone
/// silent (dead daemon / network drop — ``RemoteWindowModel/isStreamStalled``). A translucent
/// theme-derived dim over the frozen last frame + a compact spinner/label card on `.regularMaterial`
/// (native chrome; never `glassEffect` over the live Metal surface). Purely visual (the caller disables
/// hit-testing); recovery is automatic underneath (self-heal rebuild + hello retry), so there is
/// deliberately no button here.
private struct StreamStallScrim: View {
    var body: some View {
        ZStack {
            // Dim the stale frame so it reads "not live" without hiding context entirely. ONE scrim
            // spec across the canvas (UI restructure 2026-07-04): the same theme-derived veil the
            // resize scrim uses (`PaneResizeScrim`) — never a hardcoded black that fights a light theme.
            NativePaneColor.terminalBackground.opacity(0.6)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting…")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("The remote host stopped responding")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .glassPanel(radius: 8, shadowRadius: 12)
        }
    }
}

/// The bottom CONTROL bar for a LIVE window pane (issue 5): the window controls that used to clutter the pane
/// CONTENT — a "Resize…" button (opens a numeric size popover; replaced the old fiddly DRAG grip), a "lock
/// position" toggle (freezes the edge-hover auto-pan), and zoom out / reset / in (client-side compositor zoom
/// of the actual-size viewport). A native `.bar`-material strip flush along the pane bottom, separated from
/// the surface by a hairline `Divider` (never a floating card). The resize button is gated on a live
/// host-resize sink (``RemoteWindowModel/canResizeWindow``, withheld while read-only); the zoom/lock controls
/// on a live viewport sink (``RemoteWindowModel/canControlViewport``, live even while read-only — pure client ops).
private struct GuiPaneControlBar: View {
    let model: RemoteWindowModel?
    /// The store — supplies the LOCAL clipboard (current + the recent-clips ring) for the paste menu (C7).
    let store: WorkspaceStore
    /// Mirrors the pane's "lock position" state so the lock icon reflects on/off (the freeze itself lives in
    /// the video view; this toggles 1:1 with the `.toggleLock` command).
    @Binding var panLocked: Bool

    /// Whether the numeric "Resize…" size popover is open.
    @State private var showResizePopover = false

    var body: some View {
        HStack(spacing: 4) {
            // PASTE (C7): the local-clipboard affordances — "Paste as Keystrokes" (types the CURRENT local
            // clipboard into the host window) + a "Clipboard Ring" submenu of recent clips (masked preview for
            // secrets). A footer MENU rather than a surface context menu, which would steal the secondary-click
            // the pane forwards to the host window. Also reachable via ⌥⌘V + the command palette.
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
            Spacer(minLength: 8)
            if let model, model.canControlViewport {
                SlatePlateButton(symbol: .minusMagnifyingglass, help: "Zoom out") { model.sendViewport(.zoomOut) }
                SlatePlateButton(symbol: .arrowCounterclockwise, help: "Actual size (reset zoom + position)") {
                    model.sendViewport(.reset)
                }
                SlatePlateButton(symbol: .plusMagnifyingglass, help: "Zoom in") { model.sendViewport(.zoomIn) }
                SlatePlateButton(
                    symbol: panLocked ? .lockFill : .lockOpen,
                    help: panLocked ? "Unlock viewport (resume edge-pan)" : "Lock viewport position (freeze edge-pan)",
                    tint: panLocked ? Color.accentColor : Color.secondary,
                ) {
                    panLocked.toggle()
                    model.sendViewport(.toggleLock)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar) // native bottom bar material (the edge-attached footer idiom)
        .overlay(alignment: .top) {
            Divider() // hairline seam between the live surface and the footer bar
        }
    }
}

/// The numeric size popover (issue: "bỏ kéo resize, thay bằng popup set size bằng số") — set the remote
/// window's POINT size by typing width/height instead of dragging a grip. Native SwiftUI controls (per the
/// "native popups" directive): the fields pre-fill at the window's CURRENT size and cap at the host-reported
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Resize remote window")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            axisRow("Width", value: $width, range: Self.minSide...maxW)
            axisRow("Height", value: $height, range: Self.minSide...maxH)
            if let mx = model.windowMaxPointSize {
                Text("Display max \(Int(mx.width)) × \(Int(mx.height)) pt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
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
        .padding(16)
        .frame(width: 280)
        .onAppear {
            let cur = model.windowPointSize ?? CGSize(width: 1280, height: 800)
            width = clamp(Double(cur.width), Self.minSide, maxW)
            height = clamp(Double(cur.height), Self.minSide, maxH)
        }
    }

    private func axisRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
            Stepper(label, value: value, in: range, step: 20)
                .labelsHidden()
            Text("pt").foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private func apply() {
        model.resizeWindow(toWidth: clamp(width, Self.minSide, maxW), height: clamp(height, Self.minSide, maxH))
        isPresented = false
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), Swift.max(lo, hi))
    }
}

/// PASTE-AS-KEYSTROKES menu (C7): the footer affordance that makes ``RemoteWindowModel/pasteAsKeystrokes(_:)``
/// + the store's ``WorkspaceStore/clipboardRing`` REACHABLE in a remote-GUI pane — a plain ⌘V there forwards a
/// raw Cmd+V that pastes the HOST clipboard, so local text (e.g. a password for the auto-spawned SecurityAgent
/// dialog pane) could never reach a remote field. A native ``Menu``: "Paste as Keystrokes" types the CURRENT
/// local clipboard; the "Clipboard Ring" submenu lists recent clips with classifier-aware previews (secrets
/// masked). Enablement + row previews come from the headless ``ClipboardPasteMenu`` model. Disabled while the
/// pane can't type (not streaming / read-only). Mirrors the ⌥⌘V chord + the palette command.
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    hovering ? Color.primary.opacity(0.08) : .clear,
                    in: .rect(cornerRadius: 6),
                )
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .slateHelp("Paste local clipboard into the remote window as keystrokes (⌥⌘V)")
    }
}

/// The transient "typed N, skipped M" result banner (C7) for ``RemoteWindowModel/pasteAsKeystrokes(_:)`` —
/// shown only when some clipboard characters had no US-QWERTY mapping and were dropped, so the user learns a
/// paste was incomplete. Tap to dismiss (it also auto-clears on the model's timer). A floating material chip.
private struct PasteFeedbackBanner: View {
    let feedback: RemoteWindowModel.PasteFeedback
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 8) {
                Image(systemSymbol: .exclamationmarkTriangle)
                    .foregroundStyle(Color.accentColor)
                Text("Typed \(feedback.typed), skipped \(feedback.skipped) unmapped")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassPanel(radius: 6, shadowRadius: 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp("Dismiss")
    }
}
#endif
