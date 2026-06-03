#if canImport(SwiftUI)
import SwiftUI
import RworkInspector

// MARK: - PaneLeafView (WF5 — the real content seams per kind)

/// The content of a single leaf pane: the kind switch that wires the PROVEN seams (docs/22 §7),
/// re-parented from "one global session" (the retired `ClientRootView`) to "one per `PaneID`".
///
/// Its SIGNATURE is the stable WF4 contract — only the BODY is WF5:
/// - `.terminal`   → ``TerminalScreenView``(model: handle.terminalModel) + a per-pane
///   ``InputBarView``(model: handle.inputBar, client: handle.connection.activeClient), composed
///   exactly as the old `ClientRootView` did for ONE session.
/// - `.claudeCode` → the same terminal + a TOGGLEABLE ``InspectorPanel`` (per-pane VIEW state — an
///   inspector-visible toggle + a local split ratio; macOS side-by-side, iOS a bottom sheet —
///   mirroring the old `ClientRootView` platform branch). It is a SINGLE leaf, not a tree node.
/// - `.remoteGUI`  → ``RemoteWindowPanel``(model: handle.remoteWindow, showCloseButton: false) — the
///   pane chrome owns close; video decode activates on appear / deactivates on disappear (battery).
///
/// ### Connect-on-appear (docs/22 §6 RESTORED-vs-RECONNECTED, lazy connect)
/// `LivePaneSession.make` builds the `ConnectionViewModel` WITHOUT connecting. This view's `.task`
/// triggers `connect()` ONCE for the visible pane (idle → connecting). It does NOT disconnect on
/// `.onDisappear`: the session lives in the store registry and must survive tab switches; the OS-level
/// pause/resume is the store's scenePhase fan-out, not a view-lifecycle teardown.
///
/// ### The handle is `any PaneSessionHandle` (the store-level test seam, docs/22 §0)
/// The live wiring needs the concrete ``LivePaneSession`` (its `terminalModel` / `inputBar` /
/// `connection` / `inspector` / `remoteWindow`). We down-cast once; a faked handle (tests/previews)
/// has no live objects, so the leaf falls back to a kind-aware placeholder — correct for a
/// no-session render.
struct PaneLeafView: View {
    /// The live session backing this leaf, or `nil` if the registry has not materialized it yet.
    let handle: (any PaneSessionHandle)?
    /// The pure intent for this leaf (kind + title + endpoint).
    let spec: PaneSpec
    /// Whether this leaf is the focused pane of its tab (drives focus affordance + content dim).
    let isFocused: Bool
    /// The single-focus arbiter for the iOS multi-visible (iPad-regular) path (docs/22 §7). Passed by
    /// the regular ``PaneTreeView`` so each visible terminal host routes first-responder through it;
    /// `nil` on the compact single-host carousel (no race to coordinate).
    var focusCoordinator: PaneFocusCoordinator? = nil
    /// The store, threaded so a `.remoteGUI` leaf routes video activation through
    /// ``WorkspaceStore/activateVideo(_:)`` (the cap-enforcing seam). Optional so faked-handle /
    /// preview paths still construct a leaf; when `nil` the remote-GUI leaf falls back to direct
    /// activation (no cap — only the no-store preview case).
    var store: WorkspaceStore? = nil

    /// The concrete live session, when this is a production handle (the only thing that owns the
    /// proven per-session objects). `nil` for a faked handle / not-yet-materialized leaf.
    private var live: LivePaneSession? { handle as? LivePaneSession }

    var body: some View {
        Group {
            if let live {
                content(for: live)
            } else {
                placeholder
            }
        }
        .opacity(isFocused ? 1 : 0.92)
    }

    // MARK: - Kind switch (the seams)

    @ViewBuilder
    private func content(for live: LivePaneSession) -> some View {
        switch live.kind {
        case .terminal:
            TerminalPaneView(live: live, spec: spec, focusCoordinator: focusCoordinator)
        case .claudeCode:
            ClaudeCodePaneView(live: live, spec: spec, focusCoordinator: focusCoordinator)
        case .remoteGUI:
            RemoteGUIPaneView(live: live, store: store)
        }
    }

    // MARK: - Placeholder (faked handle / pre-materialize)

    /// A clean kind-aware placeholder for a faked handle or a leaf the registry has not materialized
    /// yet — keeps the shell laid out and the identity/zoom/focus plumbing exercised.
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 10) {
                Image(systemName: Self.icon(for: spec.kind))
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(spec.title).font(.headline).lineLimit(1)
                Text(kindLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let endpoint = endpointDescription {
                    Text(endpoint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kindLabel: String {
        switch spec.kind {
        case .terminal:   return "terminal"
        case .claudeCode: return "claude"
        case .remoteGUI:  return "remote"
        }
    }

    private var endpointDescription: String? {
        if let e = spec.endpoint { return "\(e.host):\(e.port)" }
        if let v = spec.video { return "\(v.host) · \(v.title)" }
        return nil
    }

    // MARK: Shared kind glyph (reused by the chrome + sidebar)

    /// The canonical SF Symbol for a ``PaneKind`` — one source of truth for the glyph so the leaf,
    /// the chrome header, and the sidebar agree.
    static func icon(for kind: PaneKind) -> String {
        switch kind {
        case .terminal:   return "terminal"
        case .claudeCode: return "sparkles"
        case .remoteGUI:  return "macwindow.on.rectangle"
        }
    }
}

// MARK: - Terminal composition (shared by .terminal and .claudeCode)

/// The proven terminal composition for ONE pane: the renderer seam over the per-pane
/// ``TerminalViewModel`` + the per-pane ``InputBarView`` bound to the SAME connection's live client,
/// composed exactly as the retired `ClientRootView` did for a single session (docs/22 §7).
///
/// ### New-pane empty state (docs/22 WF6 DECISIONS — new-pane connection flow)
/// A freshly user-created pane has NO explicit endpoint (`spec.endpoint == nil` — `store.split` /
/// `addTab` build an unconfigured spec). While such a pane is still disconnected it shows the proven
/// ``ConnectionView`` (host/port + Connect) bound to its own ``ConnectionViewModel`` — the user dials
/// in. Once connected it swaps to the terminal composite. A pane that DOES carry an explicit endpoint
/// (a restored/configured pane, or the automation seam) skips the form and AUTO-connects on appear —
/// we never blindly auto-dial a default for a user-created pane.
///
/// Owns the (gated) connect-on-appear + the `RWORK_AUTOTYPE` OUT-path proof seam (both keyed off the
/// `LivePaneSession`'s own `connection`). Used directly for `.terminal` and embedded by
/// ``ClaudeCodePaneView`` for `.claudeCode`.
private struct TerminalContentView: View {
    let live: LivePaneSession
    /// The pure intent — read for `spec.endpoint` to decide auto-connect vs. the connect form.
    let spec: PaneSpec
    /// The single-focus arbiter forwarded to the iOS ``InputBarView`` → ``TerminalInputHost`` so the
    /// host registers under this pane's id (docs/22 §7). `nil` ⇒ direct-claim (compact / macOS).
    var focusCoordinator: PaneFocusCoordinator? = nil

    /// Whether this pane carries an explicit endpoint (restored / configured / automation). Only such
    /// a pane auto-connects on appear; a fresh user pane shows the connect form first.
    private var hasExplicitEndpoint: Bool { spec.endpoint != nil }

    var body: some View {
        Group {
            if showConnectForm {
                connectForm
            } else {
                terminalComposite
            }
        }
        // Lazy connect ONCE on appear (docs/22 §6) — but ONLY for a pane with an explicit endpoint.
        // A fresh user pane (no endpoint) waits for the user's Connect in the form. Not connected on
        // disappear — the session survives tab switches in the store registry. Re-entrancy-safe:
        // `connect()` tears down a prior session first, but we only call it from a fresh idle pane.
        .task { await connectIfNeeded() }
    }

    /// Show the connect form when this pane has no explicit endpoint AND is not yet live — i.e. a
    /// fresh user-created pane awaiting host/port. Once it connects (or while connecting/reconnecting)
    /// the terminal composite is shown instead. A pane with an explicit endpoint never shows the form
    /// (it auto-connects).
    private var showConnectForm: Bool {
        guard !hasExplicitEndpoint, let connection = live.connection else { return false }
        switch connection.status {
        case .disconnected, .failed: return true
        case .connecting, .connected, .reconnecting: return false
        }
    }

    /// The new-pane empty state: the proven ``ConnectionView`` (host/port + Connect) over this pane's
    /// own ``ConnectionViewModel``. Centered so it reads as an empty state, not a toolbar.
    @ViewBuilder
    private var connectForm: some View {
        if let connection = live.connection {
            VStack(spacing: 12) {
                Image(systemName: PaneLeafView.icon(for: spec.kind))
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Connect to a host")
                    .font(.headline)
                ConnectionView(model: connection)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            Color.clear
        }
    }

    /// The proven terminal composite (renderer + input bar), shown once the pane is connecting/live or
    /// when it carries an explicit endpoint.
    private var terminalComposite: some View {
        VStack(spacing: 0) {
            if let terminalModel = live.terminalModel {
                TerminalScreenView(model: terminalModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if let inputBar = live.inputBar {
                Divider()
                // The input bar binds the SAME connection's live client (nil while disconnected, so
                // the bar disables send). The proven OUT path: bar → client.sendInput → ordered drain.
                // The pane id + coordinator drive the iOS first-responder arbiter (docs/22 §7).
                InputBarView(
                    model: inputBar,
                    client: live.connection?.activeClient,
                    paneID: live.id,
                    focusCoordinator: focusCoordinator
                )
            }
        }
    }

    /// Triggers the connection's lazy `connect()` for a fresh idle pane that carries an EXPLICIT
    /// endpoint, then runs the `RWORK_AUTOTYPE` OUT-path proof if this is the automation target
    /// (tab0/pane0). A pane with no explicit endpoint is NOT auto-dialed — the user drives Connect via
    /// the form (docs/22 WF6 DECISIONS).
    private func connectIfNeeded() async {
        guard hasExplicitEndpoint, let connection = live.connection else { return }
        // Only connect a freshly-materialized idle pane; never re-dial a live/connecting one (a tab
        // switch re-runs `.task`, and `.id(PaneID)` keeps this view stable across reshapes).
        if connection.status == .disconnected {
            await connection.connect()
        }
        await runAutotypeIfRequested(connection: connection)
    }

    /// The `RWORK_AUTOTYPE` OUT-path proof seam (docs/22 §7), migrated verbatim from the retired
    /// `RworkClientApp.autoConnectIfRequested`. After tab0/pane0's terminal connects, if `RWORK_AUTOTYPE`
    /// is set, push the command bytes through the REAL OUT path — `terminalModel.sendInput` →
    /// `inputSink` → the ordered drain in `ConnectionViewModel` → `RworkClient.sendInput` → host PTY:
    /// the EXACT keystroke→host chain `GhosttyTerminalView` drives, so a typed command actually
    /// executes on the host and renders back. `scripts/check-macos.sh --connect` asserts this round
    /// trip (a host-side marker file with a COMPUTED value), not just a live TCP socket. Unset in
    /// normal use, so a production launch is unaffected.
    @MainActor
    private func runAutotypeIfRequested(connection: ConnectionViewModel) async {
        guard live.isAutotypeTarget else { return }
        let env = ProcessInfo.processInfo.environment
        guard case .connected = connection.status,
              let cmd = env["RWORK_AUTOTYPE"], !cmd.isEmpty,
              let terminalModel = live.terminalModel else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the remote prompt come up
        terminalModel.sendInput(Data((cmd + "\n").utf8))
    }
}

/// A `.terminal` leaf: the terminal composition, full-bleed.
private struct TerminalPaneView: View {
    let live: LivePaneSession
    let spec: PaneSpec
    var focusCoordinator: PaneFocusCoordinator? = nil
    var body: some View { TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator) }
}

// MARK: - Claude Code composition (terminal + toggleable inspector)

/// A `.claudeCode` leaf: the proven terminal composition PLUS a TOGGLEABLE read-only ``InspectorPanel``
/// fed by the pane's own inspector second channel (NWConnection #2). The inspector-visible toggle + the
/// local split ratio are per-pane VIEW state — NOT a tree node (a Claude Code pane is a single leaf,
/// docs/22 §2.3). Platform branch mirrors the retired `ClientRootView`:
/// - **macOS**: terminal + inspector side-by-side, divider toggled by a header button.
/// - **iOS**: terminal full-bleed, inspector as a bottom sheet.
private struct ClaudeCodePaneView: View {
    let live: LivePaneSession
    /// The pure intent — forwarded to ``TerminalContentView`` so a fresh Claude Code pane shows the
    /// connect form until it is dialed in (docs/22 WF6 new-pane connection flow).
    let spec: PaneSpec
    /// The single-focus arbiter forwarded to the embedded terminal composition (docs/22 §7).
    var focusCoordinator: PaneFocusCoordinator? = nil
    /// Per-pane VIEW state: whether the inspector is shown. Local to this leaf — lost on a true
    /// session swap (a new `PaneID`), preserved across reshape/zoom/focus (stable `.id`).
    @State private var showInspector = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorToggleBar
            Divider()
            content
        }
        // Open + fold the inspector second channel once (full replay → live), via the session's single
        // fold point. Mirrors `LivePaneSession.subscribeInspector` (idempotent; re-tail-safe). We do
        // NOT also pass the client to `InspectorPanel` — that would double-subscribe the same stream.
        .task { await live.subscribeInspector() }
    }

    /// macOS: terminal + (optional) inspector side-by-side. iOS: terminal full-bleed; inspector sheet.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, let model = live.inspector {
                Divider()
                InspectorPanel(model: model)
                    .frame(minWidth: 280, maxWidth: 420)
            }
        }
        #else
        TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator)
            .sheet(isPresented: $showInspector) {
                if let model = live.inspector {
                    InspectorPanel(model: model)
                        .presentationDetents([.medium, .large])
                }
            }
        #endif
    }

    /// The inspector-visible toggle (per-pane). A thin strip above the content so the affordance is
    /// reachable on both platforms without depending on the global toolbar.
    private var inspectorToggleBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                showInspector.toggle()
            } label: {
                Label(
                    "Inspector",
                    systemImage: showInspector ? "sidebar.right" : "sidebar.squares.right"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide inspector" : "Show inspector")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
            .disabled(live.inspector == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Remote GUI composition (video)

/// The three things a `.remoteGUI` leaf can show, decided PURELY from
/// `(admitted, configured, hasFreeSlot)` so the branch is unit-testable without a SwiftUI render
/// (BUG-A + the F1 regression fix).
enum RemoteGUIDisplay: Equatable {
    /// The live ``RemoteWindowPanel`` (admitted to a cap slot — its decode stack may run).
    case live
    /// The ``RemoteWindowPanel`` entry FORM: either the model is not yet configured (no host/port — the
    /// user must dial it in), OR it just became configured while a cap slot IS free (so admission is
    /// about to be auto-attempted and flip the pane to `.live` — the form must NOT vanish before then).
    /// Holds NO decode stack (`model.active == nil`).
    case entryForm
    /// The cap-saturated placeholder: the model IS configured AND no slot is free, so admission was
    /// refused specifically because ``WorkspaceStore/liveVideoCap`` is saturated (BUG-A — distinct from
    /// the unconfigured / free-slot `.entryForm`).
    case gated

    /// The PURE display decision (BUG-A + F1) — free of any SwiftUI / store state so it is unit-tested
    /// directly:
    /// - `admitted` ⇒ `.live`;
    /// - else NOT configured ⇒ `.entryForm` (let the user dial in — never gate an unconfigured pane);
    /// - else configured AND a slot IS free ⇒ `.entryForm` (the form stays until the reactive retry
    ///   admits the now-configured pane and flips `admitted` true — F1: the form must not disappear
    ///   the instant the endpoint becomes valid);
    /// - else (configured AND no free slot) ⇒ `.gated` (admission was genuinely refused by the cap).
    static func resolve(admitted: Bool, configured: Bool, hasFreeSlot: Bool) -> RemoteGUIDisplay {
        if admitted { return .live }
        guard configured else { return .entryForm }
        return hasFreeSlot ? .entryForm : .gated
    }
}

/// A `.remoteGUI` leaf: the live ``RemoteWindowPanel`` with the pane-chrome owning close
/// (`showCloseButton: false`). Video decode activates on appear / deactivates on disappear so a
/// hidden / torn-down pane holds no decode stack (docs/22 §7 the video resource ceiling).
///
/// Activation is routed through ``WorkspaceStore/activateVideo(_:)`` so the `liveVideoCap` is actually
/// enforced at runtime (the store self-excludes this pane + counts other active video panes). Without a
/// store (preview / faked path) it falls back to direct, un-capped activation.
///
/// ### Two reasons admission can be `false` (BUG-A) + the F1 regression fix
/// `activateVideo` (and direct activation) can decline for two very different reasons, which this view
/// MUST distinguish — otherwise an unconfigured pane is stuck forever on a wrong "too many windows"
/// placeholder with no way to enter host/port:
/// - the model is **not yet configured** (`remoteWindow.canOpen == false` — a fresh New-Tab/split
///   Remote Window has `video: nil` → `RemoteWindowModel()` with empty fields) ⇒ show the
///   ``RemoteWindowPanel`` ENTRY FORM so the user can dial in the endpoint (it holds no decode stack
///   until they open it);
/// - the model **is configured** (`canOpen == true`) but the cap is saturated ⇒ show the gated
///   placeholder (and re-attempt when a slot frees, ITEM #2).
///
/// The store's `false` alone cannot tell those apart (`activateVideo` returns `false` for both). So the
/// display is decided by ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)`` fed BOTH
/// `configured` (the model's `canOpen`) and `hasFreeSlot` (the store's pure
/// ``WorkspaceStore/hasFreeVideoSlot(for:)`` read mirroring the admission guard): a configured pane with
/// a slot still FREE keeps showing the entry form (F1 — the form must not vanish the instant the
/// endpoint becomes valid), and only a configured pane refused because the cap is genuinely saturated
/// shows `.gated`.
///
/// ### Reactive admission (ITEM #2 + F1)
/// The store cannot flip a pane's liveness itself — admission is view-driven. Two reactive re-attempts:
/// - **F1 — became configured**: a fresh pane's `.onAppear` ran while `canOpen` was still false, so it
///   never admitted. When the user finishes typing a valid endpoint `configured` flips true; this view
///   observes it via `.onChange(of: configured)` and re-runs `activate()` (→ `activateVideo`, still
///   cap-checked) so a configured pane with a free slot goes live without a manual nudge.
/// - **ITEM #2 — a slot freed**: when a slot frees the store bumps
///   ``WorkspaceStore/videoPromotionGeneration``; this view observes it via `.onChange` and re-attempts
///   admission through `activateVideo`, so a previously-gated on-screen pane promotes itself the moment
///   a slot opens.
private struct RemoteGUIPaneView: View {
    let live: LivePaneSession
    /// The cap-enforcing store. `nil` only on the no-store preview path.
    var store: WorkspaceStore?
    /// Whether this pane was admitted to hold live video (the store said yes, or the no-store fallback
    /// activated it). When `false` the pane shows the entry form (unconfigured) or the gated placeholder
    /// (configured but over-cap) per ``RemoteGUIDisplay``.
    @State private var admitted = false

    /// Debounced video teardown (the autoconnect-connect fix). SwiftUI fires a SPURIOUS
    /// `.onDisappear` on this pane during the initial NavigationSplitView layout settle — even
    /// though the pane stays on screen. The battery "deactivate on disappear" optimization then
    /// ran `model.close()` (active=nil) → the `VideoWindowView` was dismantled → its UDP session
    /// `stop()`'d WHILE `session.start()` was mid-`await transport.start`, so `stateMachine.start()`
    /// saw `.stopped` and produced ZERO effects → the `hello` was never sent → autoconnect never
    /// connected. (The manual dial-in flow opens the video AFTER the shell has settled, so it never
    /// saw the spurious disappear — which is why it always worked.) We DEFER the teardown by a short
    /// delay and CANCEL it if the pane re-appears (or activates) in the meantime; only a disappear
    /// that actually persists (a real tab switch) tears the decode stack down.
    @State private var teardownTask: Task<Void, Never>?

    /// Whether the remote-window model parses to a complete endpoint (host/port/window all valid). A
    /// fresh user-created `.remoteGUI` pane is NOT configured (empty fields → `canOpen == false`). This
    /// reads the `@Observable` ``RemoteWindowModel`` fields, so it re-evaluates on the keystroke that
    /// completes a valid endpoint — which drives the F1 reactive retry below.
    private var configured: Bool { live.remoteWindow?.canOpen == true }

    /// Whether the store currently has a free live-video slot for THIS pane (mirrors `activateVideo`'s
    /// guard with no mutation). The no-store preview path has no cap, so it is always free there. Fed
    /// into ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)`` so a configured-but-unadmitted
    /// pane shows the entry form while a slot is free (F1 — the form must stay until the retry admits it)
    /// and only the gated placeholder once the cap is genuinely saturated.
    private var hasFreeSlot: Bool { store?.hasFreeVideoSlot(for: live.id) ?? true }

    var body: some View {
        Group {
            if let model = live.remoteWindow {
                // `.entryForm` and `.live` render the IDENTICAL `RemoteWindowPanel`; only `.gated`
                // differs. They MUST share ONE stable SwiftUI identity — rendering the panel from two
                // separate `switch` branches makes SwiftUI RECREATE the `VideoWindowView` when
                // `admitted` flips `entryForm→live`, tearing down its just-built UDP session before the
                // queued `hello` flushes (the synchronous cursor-prime survives, the hello does not), so
                // the AUTOCONNECT path never connects. The panel itself shows the form vs. live video off
                // `model.active`; admission only gates whether `open()` was allowed to run. (The manual
                // dial-in flow stays in `.live` throughout, which is why it was never affected.)
                if RemoteGUIDisplay.resolve(admitted: admitted, configured: configured, hasFreeSlot: hasFreeSlot) == .gated {
                    gatedPlaceholder
                } else {
                    RemoteWindowPanel(model: model, showCloseButton: false)
                }
            } else {
                Color.clear
            }
        }
        // Activate on appear (decode only the on-screen pane), deactivate on disappear (battery).
        // Routed through the store so `liveVideoCap` is enforced; the no-store preview path activates
        // directly. The store reads `isVideoActive` to count concurrent live video panes.
        .onAppear { cancelPendingTeardown(); activate() }
        // Backstop for .onAppear: a configured (restored / autoconnect) pane is ALREADY configured at
        // mount, so `.onChange(of: configured)` never fires, and `.onAppear` alone is unreliable — it is
        // deferred until the NavigationSplitView detail subtree is actually displayed, so an autoconnect
        // launch (and any launch where the window isn't front yet) sits on the form instead of going
        // live. `.task` runs reliably on view-install; `activate()` is cap-checked + the `!admitted`
        // guard makes the double-trigger idempotent (an unconfigured pane still no-ops → entry form, so
        // the manual dial-in flow is unchanged). This is the one-shot autoconnect fix.
        .task { cancelPendingTeardown(); if !admitted { activate() } }
        .onDisappear { scheduleTeardown() }
        // F1 — a fresh pane's .onAppear ran while the model was still UNconfigured (`canOpen == false`),
        // so `activate()` never admitted it and there was no re-attempt once the user finished typing a
        // valid endpoint. Re-attempt admission the instant the model becomes configured: the keystroke
        // that flips `canOpen` true flips `configured`, and this re-runs `activate()` (→ `activateVideo`,
        // still cap-checked). If a slot is free the pane goes live; if not it falls to the gated
        // placeholder — correct, because now admission was genuinely refused by the cap.
        .onChange(of: configured) { _, nowConfigured in
            if nowConfigured { activate() }
        }
        // ITEM #2 — when the store nudges `videoPromotionGeneration` (a slot freed), an on-screen pane
        // that was previously gated re-attempts admission. Cap-safe: the retry flows through
        // `activateVideo`. `nil` (no-store preview) never bumps, so this is inert there.
        .onChange(of: store?.videoPromotionGeneration) { _, _ in retryIfGated() }
    }

    /// Requests a cap slot for this pane (store path) or activates directly (no-store preview path).
    private func activate() {
        if let store {
            admitted = store.activateVideo(live.id)
        } else {
            live.setVideoActive(true)
            admitted = live.isVideoActive
        }
    }

    /// Cancels a pending debounced teardown — the pane re-appeared (or re-activated), so the
    /// `.onDisappear` that scheduled it was spurious and the decode stack must stay up.
    private func cancelPendingTeardown() {
        teardownTask?.cancel()
        teardownTask = nil
    }

    /// Schedules the video teardown after a short grace period instead of running it inline on
    /// `.onDisappear`. A spurious initial-layout disappear is followed immediately by a re-appear
    /// (or the `.task`) which cancels this; only a disappear that OUTLASTS the grace period (a real
    /// tab switch / pane close) actually deactivates. This is the autoconnect-connect fix — the
    /// inline teardown used to stop the session mid-`start()` so the hello was never sent.
    private func scheduleTeardown() {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            // The disappear was SPURIOUS if the pane is still a leaf of the active tab (SwiftUI
            // sent a lone `.onDisappear` during the initial layout settle but the pane never left
            // the screen, and `.onAppear` does NOT re-fire to cancel us). Only a REAL disappear —
            // the pane has left the active tab (a genuine tab switch / close) — actually tears down.
            if let store, store.isPaneOnActiveTab(live.id) {
                teardownTask = nil
                return
            }
            if let store {
                store.deactivateVideo(live.id)
            } else {
                live.setVideoActive(false)
            }
            admitted = false
            teardownTask = nil
        }
    }

    /// Re-attempts admission for a gated pane when the store signals a freed slot (ITEM #2). A no-op for
    /// an already-admitted pane (so an unrelated bump never re-churns a live pane) and for the no-store
    /// preview path. The retry still flows through `activateVideo`, so the cap is never breached.
    private func retryIfGated() {
        guard !admitted, let store else { return }
        admitted = store.activateVideo(live.id)
    }

    /// Shown when the cap is saturated AND the model is configured (BUG-A): the pane is on-screen but
    /// NOT decoding (no UDP / VTDecompress / CADisplayLink) because no slot is free. An UNconfigured
    /// pane never reaches here — it shows the entry form instead.
    private var gatedPlaceholder: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 10) {
                Image(systemName: "pause.rectangle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Video paused")
                    .font(.headline)
                Text("waiting for a free video slot")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
