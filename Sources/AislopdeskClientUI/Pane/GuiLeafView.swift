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
// registers no factory, so `VideoWindowFactory.make` yields an `EmptyView`. SYSTEM/Otty tokens only.

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
    /// E21 WI-4 (ES-E21-2): the app-global connection host (`ConnectionTarget.host`) for the bottom status
    /// bar's right field — empty when not yet connected / unknown (the strip then omits it). Passed down from
    /// ``PaneContainer`` (which already resolves the same value for the terminal leaf).
    var host: String = ""

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
            // E21 WI-4 (ES-E21-2): the SAME flat ≤20pt bottom status bar a terminal leaf carries, so a focused
            // `.remoteGUI` / `.systemDialog` pane is a first-class peer with the host + kind label visible. The
            // pure ``StatusBarContent`` model gives a video pane an EMPTY cwd and OMITS the exit badge
            // (``StatusBarContent/exitBadge(lastCommand:kind:)`` returns `.none` for a non-terminal kind), so only
            // the "remote" / "dialog" label + the host render. `model: nil` (a video pane has no
            // ``TerminalViewModel`` — the badge then follows the kind alone) and `hoverFullPath: nil` (no ⌘-hover
            // links on a video surface). Gated `!staticMirror && !hideStatusBar`, exactly like ``TerminalLeafView``.
            if showStatusBar {
                StatusBarStrip(
                    model: nil,
                    cwd: nil,
                    kind: paneKind,
                    host: host,
                    hoverFullPath: nil,
                )
            }
        }
        .background(NativePaneColor.terminalBackground)
        // CAP ADMISSION (A2): request a slot on appear AND re-attempt whenever a sibling frees one
        // (`videoPromotionGeneration` bumps). `.task(id:)` cancels+restarts on either change. NEVER
        // calls `live.setVideoActive` directly — the store enforces the cap + tearingDownVideo
        // accounting. iOS resume re-activates `wasVideoActiveBeforePause` inside `LivePaneSession.resume`,
        // so this activate is idempotent there (an already-active pane returns true without churn).
        .task(id: activationKey) {
            guard !staticMirror, model != nil else { return }
            _ = store.activateVideo(paneID)
        }
        // A tab-switch unmounts the leaf → free the cap slot (close/detach already flows through
        // `reconcile` → `teardown`, this only handles the on-screen disappear, A5).
        .onDisappear {
            guard !staticMirror else { return }
            store.deactivateVideo(paneID)
        }
    }

    /// The `.task` identity: re-run admission when THIS session changes (mount) OR a sibling frees a slot.
    private var activationKey: String { "\(live?.id.hashValue ?? 0):\(store.videoPromotionGeneration)" }

    /// E21 WI-4: whether the bottom status bar mounts on this video pane — NOT the static-mirror snapshot path
    /// and the `Hide Status Bar` setting (``SettingsKey/hideStatusBarEnabled``) off. Mirrors ``TerminalLeafView``'s
    /// gate minus the terminal-model requirement (a video pane has no `terminalModel`), so the strip rides the
    /// live surface, the in-pane picker AND the cap-gated placeholder — the host + kind label apply in all three.
    private var showStatusBar: Bool {
        !staticMirror && !SettingsKey.hideStatusBarEnabled
    }

    /// E21 WI-4: the pane's kind for the status-bar label — the live session's kind once it materializes, else
    /// the spec's kind from the store (so a not-yet-live `.systemDialog` still reads "dialog"), defaulting to
    /// `.remoteGUI` (the only kinds routed to this leaf are `.remoteGUI` / `.systemDialog`).
    private var paneKind: PaneKind {
        live?.kind ?? store.tree.activeSession?.specs[paneID]?.kind ?? .remoteGUI
    }

    @ViewBuilder private var content: some View {
        if staticMirror {
            // STATIC snapshot: never a live decode — the placeholder mirror only.
            placeholder(.entryForm)
        } else {
            switch display {
            case .live:
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
                ),
            )
        }
    }

    /// The native placeholder for the non-live states: the cap-gated "video paused" notice, or the bare
    /// idle mirror used on the static snapshot path.
    private func placeholder(_ state: RemoteGUIDisplay) -> some View {
        VStack(spacing: Otty.Metric.space3) {
            Image(systemSymbol: live?.kind == .systemDialog ? .lockShield : .display)
                .font(.system(size: Otty.Typeface.display, weight: .regular))
                .foregroundStyle(Otty.Text.secondary)
            Text(placeholderLabel(state))
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    private func placeholderLabel(_ state: RemoteGUIDisplay) -> String {
        if state == .gated { return "Video paused — too many live streams" }
        return live?.kind == .systemDialog ? "system dialog" : "remote window"
    }
}
#endif
