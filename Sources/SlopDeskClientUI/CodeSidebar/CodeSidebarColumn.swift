// CodeSidebarColumn — the RIGHT sidebar: the project-scoped embedded VS Code (code-server in a
// pooled WKWebView). Project-scoped means the ACTIVE pane picks the project (its host-pushed
// `projectKey` — the same key the left panel's sections group by), and every pane of that project
// shares the ONE workbench opened at the project root; focusing a pane of another project swaps the
// warm webview for THAT project back in (see `CodeSidebarWebViewPool`).
//
// The column is macOS-only chrome hosted in its own plain `NSSplitViewItem` (a THIRD column beside
// navigator | content — never `.inspector`, whose collapse unmounts the content and would kill the
// webview's layout). While collapsed the split item unparents this view, SwiftUI cancels the
// `.task`, and the poll loop stops — the code-server is only ever ensured when the panel is open.
//
// The panel carries its OWN top strip (the otty right-panel pattern): a REAL tab row — "Files"
// (the embedded workbench; renamed from "Code" with the `folder` glyph, user-directed
// 2026-08-03) and "Desktop" (the window-OS surface; its content is still a
// placeholder) — plus the trailing actions: the reload plate (Files only) and the panel's HIDE
// toggle at the far trailing corner (user-directed 2026-08-03 — the same split the left sidebar
// has: hide inside the surface, reopen in the titlebar). The selected tab expands to icon +
// label, the other collapses to its icon; clicking crossfades the surface below.

#if os(macOS)
import SFSafeSymbols
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct CodeSidebarColumn: View {
    let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    let connection: AppConnection
    /// The shared chrome state — the strip's trailing HIDE toggle flips its
    /// `codeSidebarCollapsed` flag (the titlebar keeps only the collapsed-state reopen).
    let chrome: WorkspaceChromeState
    /// The live preferences store (nil only in previews/automation shells) — the terminal font
    /// prefs the panel pushes host-side (verb 20) so the editor reads like the terminal beside it.
    /// Passed explicitly: this column lives in its own `NSHostingController`, which does NOT
    /// inherit the WindowGroup's `\.preferencesStore` environment.
    let preferences: PreferencesStore?

    @State private var model = CodeSidebarModel()

    /// The panel surface the strip's tab row selects. Per-window view state (the hosting
    /// controller keeps the SwiftUI hierarchy across collapse/expand, so the choice survives a
    /// hide — but not a relaunch; the panel always comes back on Code, the primary surface).
    enum SurfaceTab {
        case code
        case simulators
        case desktop
    }

    @State private var surfaceTab: SurfaceTab = .code
    @State private var simulatorModel = SimulatorSidebarModel()

    private var activePane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the
    /// cwd fallback the sidebar sections tolerate (`paneProjectKey`). Ensuring on the transient
    /// pre-push cwd spawns a code-server for a root the project does not have (observed: the shell's
    /// start directory vs the git toplevel — two Node processes for one project, one stranded).
    /// `nil` ⇒ no pane focused, or the push hasn't landed yet (see `awaitingProjectKey`).
    private var activeProjectRoot: String? {
        guard let pane = activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the focused pane already has a SECTION identity (the cwd fallback) but no host-pushed
    /// key yet — the first push is in flight, so render a brief waiting surface instead of the
    /// no-project placeholder. The mirror write re-renders this view the moment the key lands.
    private var awaitingProjectKey: Bool {
        guard let pane = activePane, activeProjectRoot == nil else { return false }
        return store.paneProjectKey(pane) != nil
    }

    /// The client's current terminal-font spec — recomputed whenever the observed terminal prefs
    /// change (the store is `@Observable`; reading `terminal` here subscribes the view).
    private var fontSpec: MetadataCodec.CodeFontSpec? {
        preferences.map { CodeFontSync.spec(terminal: $0.terminal) }
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            // The strip's bottom edge: the Slate divider hairline — the SAME faint fg-tint the
            // split divider carries (batch 12's one visual language for seams). Without it the
            // ground band ends in an abrupt tone change against the workbench's own tab strip,
            // two mismatched grays stacked with no rule between them.
            //
            // It stays for EVERY surface (user-directed 2026-08-04, after a round that made it
            // conditional): the tab row is chrome that outranks whatever it switches between, and
            // chrome without an edge floats. The stacked-hairline complaint it was meant to fix
            // belonged to the SECOND rule — the device header's — which is the one that went.
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            // A bare switch: the surfaces carry no animation of their own — whatever motion the
            // swap has rides the `selectSurface` transaction, exactly like the pre-removal
            // inspector's content switch under its `withAnimation` tab write.
            switch surfaceTab {
            case .code:
                surface
            case .simulators:
                simulatorSurface
            case .desktop:
                // The announced window-OS surface — content still a placeholder; the TAB is real
                // (selecting it parks the Code surface, whose pooled webview survives unmounted
                // exactly like a project switch, and cancels the ensure poll until Code returns).
                placeholder(
                    symbol: .display,
                    title: "Desktop",
                    detail: "The host's window surface arrives here.",
                )
            }
        }
        .background(Slate.Surface.ground)
        // A LIVE font-prefs change while the panel is open re-syncs immediately (the workbench's
        // settings watcher applies it without a reload). The ensure-round sync below covers the
        // panel-open path; this covers Settings edits mid-session. Best-effort, reply ignored.
        .onChange(of: fontSpec) { _, spec in
            guard let spec, let client = Self.firstConnectedMetadataClient(store) else { return }
            // Records the push too, so the next ensure round does not re-send what just landed.
            Self.lastPushedFontSpec = spec
            Task { await client.syncCodeFont(spec) }
        }
    }

    /// The panel's OWN top strip (user-directed: the tabs belong to the panel, over the panel,
    /// never over the terminal). Tab plates lead, actions trail (the otty strip layout); the row
    /// is CENTERED in the strip band (user-directed 2026-08-03, overriding the earlier
    /// titlebar-row top-anchor). Tab vocabulary is otty's: the SELECTED surface expands to
    /// icon + label, every other tab collapses to its icon; both tabs are REAL (click = switch
    /// the surface below). Desktop's glyph is `display`, the app's existing GUI-surface
    /// vocabulary (`macwindow` read as a blob at strip size — user-rejected). The reload plate
    /// rides only the Code surface (Desktop has nothing to reload); the far trailing corner is
    /// the panel's HIDE toggle (user-directed 2026-08-03 — moved here from the terminal's
    /// titlebar, which now carries only the collapsed-state reopen).
    /// A tab click animates through ONE `withAnimation(standard)` transaction around the state
    /// write — the pre-removal inspector's choreography (`InspectorColumn.tabButton`, resurrected
    /// user-directed 2026-08-03). The transaction carries the plate relayout, the reload plate's
    /// arrival, and the surface swap together; there are NO per-view `.animation` modifiers on
    /// this path (two redesigns that added them were both rejected).
    private func selectSurface(_ tab: SurfaceTab) {
        withAnimation(Slate.Anim.standard) { surfaceTab = tab }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            PanelTabPlate(
                // The folder register (user-directed 2026-08-03), not a lone document — the tab
                // opens the whole project tree. `folder` also sidesteps the deprecated `doc`
                // family (SF6 renamed it wholesale; the new constants outrun the package floor).
                symbol: .folder, label: "Files",
                selected: surfaceTab == .code,
            ) { selectSurface(.code) }
                .help("Files — the project's embedded editor")
            // Simulators sits beside Files because it is the other REAL surface — a live host
            // resource, not the announced-but-empty Desktop.
            PanelTabPlate(
                symbol: .iphone, label: "Simulators", selected: surfaceTab == .simulators,
            ) { selectSurface(.simulators) }
                .help("Simulators — the host's iOS Simulator devices")
            PanelTabPlate(symbol: .display, label: "Desktop", selected: surfaceTab == .desktop) {
                selectSurface(.desktop)
            }
            .help("Desktop — the host's window surface")
            Spacer(minLength: 0)
            if surfaceTab == .code { activeEditorReadout }
            switch surfaceTab {
            case .code:
                PlateIconButton(symbol: .arrowClockwise) {
                    guard let root = activeProjectRoot else { return }
                    CodeSidebarWebViewPool.shared.reload(projectRoot: root)
                    model.requestReload()
                }
                .help("Reload the workbench")
            case .simulators:
                // No back control here: leaving a device is navigation within the surface, and it
                // now sits beside the device's own name in `SimulatorDeviceHeader` — where every
                // other split view in the app puts it. This strip stays surface-level verbs only.
                PlateIconButton(symbol: .arrowClockwise) { simulatorModel.requestReload() }
                    .help("Reload the simulator list")
            case .desktop:
                EmptyView()
            }
            PlateIconButton(symbol: .sidebarRight) {
                chrome.toggleCodeSidebar()
            }
            .help("Hide the right panel")
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.titlebarHeight)
    }

    /// The active editor's name (plus an unsaved-changes dot) read straight off the workbench's
    /// document title — see ``CodeSidebarWorkbenchTitle``. It sits between the tab plates and the
    /// actions, in the secondary register: this is a glance-readout, not a control. The workbench
    /// renders the same fact in its own tab, so when nothing is open the readout says nothing
    /// rather than reserving space for an em-dash.
    @ViewBuilder
    private var activeEditorReadout: some View {
        if let root = activeProjectRoot,
           let editor = CodeSidebarWebViewPool.shared.readout(for: root).activeEditor
        {
            HStack(spacing: Slate.Metric.space1) {
                if editor.dirty {
                    Circle()
                        .fill(Slate.Text.secondary)
                        .frame(width: Slate.Metric.dot, height: Slate.Metric.dot)
                }
                Text(editor.name)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(editor.dirty ? "\(editor.name) — unsaved changes" : editor.name)
            .padding(.trailing, Slate.Metric.space1)
        }
    }

    /// The workbench surface below the strip — phase-switched per the active project.
    private var surface: some View {
        Group {
            if let root = activeProjectRoot {
                content(projectRoot: root)
                    // Restart the poll on a project switch or a manual reload — SwiftUI cancels the
                    // running loop with the old id, so at most one loop ensures at a time.
                    .task(id: "\(root)#\(model.generation)") {
                        await model.poll(
                            projectRoot: root,
                            host: { [connection] in connection.target.host },
                            ensure: { [store, preferences] in
                                await Self.ensureEndpoint(
                                    projectRoot: $0, store: store, preferences: preferences,
                                )
                            },
                            // Front the remote endpoint with the loopback relay: a secure browser
                            // context (no insecure-context toast) on an origin that survives
                            // respawns. On bind failure the remote address rides through — the ATS
                            // arbitrary-loads exception keeps that fallback loadable.
                            localize: { host, port in
                                await CodeSidebarProxyPool.shared.endpoint(host: host, port: port)
                                    ?? (host, port)
                            },
                        )
                    }
            } else if awaitingProjectKey {
                waiting("Resolving project…")
            } else {
                placeholder(
                    symbol: .folder,
                    title: "No project in focus",
                    detail: "Focus a terminal pane to open its project here.",
                )
            }
        }
    }

    /// The phase surface for the active project. The webview mounts ONLY in a `.ready` whose root
    /// matches the ACTIVE project — a `.ready` still carrying the previous project (the render
    /// between a switch and its restarted poll) renders the waiting surface instead. Minting the
    /// pool's webview from that stale phase opened the OLD project's folder for the new root and
    /// stuck there (user-reported 2026-08-03; the pool re-loads only on a host/port move). The
    /// pooled instance underneath survives the unmount (project switches are warm swaps).
    @ViewBuilder
    private func content(projectRoot: String) -> some View {
        switch model.phase {
        case let .ready(root, url) where root == projectRoot:
            webContent(projectRoot: projectRoot, url: url)
        case .ready,
             .starting:
            waiting("Starting code-server…")
        case .unavailable:
            placeholder(
                symbol: .shippingbox,
                title: "code-server not found on host",
                detail: "brew install code-server",
                detailIsCommand: true,
            )
        case .offline:
            placeholder(
                symbol: .boltSlash,
                title: "Host unreachable",
                detail: "The editor opens once a pane is connected.",
            )
        }
    }

    /// The mounted webview under its first-paint VEIL: the dark waiting surface stays on top from
    /// load-start until the main-frame navigation settles, then fades — without it the boot reads
    /// as black → WebKit's white canvas → workbench. The veil state is per-project and pooled with
    /// the webview, so a warm project swap mounts unveiled (no spurious spinner).
    @ViewBuilder
    private func webContent(projectRoot: String, url: URL) -> some View {
        let veiled = CodeSidebarWebViewPool.shared.loadState(for: projectRoot).veiled
        CodeSidebarWebView(projectRoot: projectRoot, url: url)
            .overlay {
                if veiled {
                    waiting("Opening workbench…")
                        .background(Slate.Surface.ground)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.smallFade, value: veiled)
    }

    /// The Simulators surface. Machine-scoped, so unlike the workbench it has no project to key on
    /// and no waiting-for-projectKey state: one ensure loop, one device list, one live stream.
    ///
    /// The two `.task`s live on the surface rather than the column, which is what makes both LAZY:
    /// selecting another tab (or collapsing the panel) unmounts this and SwiftUI cancels them, so a
    /// user who never opens this tab never causes the host to spawn a simulator server at all — and
    /// leaving the tab drops the device poll and the live stream rather than paying for them
    /// off-screen.
    private var simulatorSurface: some View {
        Group {
            switch simulatorModel.phase {
            case .ready:
                simulatorReadyContent
            case .starting:
                waiting("Starting simulator server…")
            case .unavailable:
                placeholder(
                    symbol: .iphoneSlash,
                    title: "baguette not found on host",
                    detail: "brew install baguette",
                    detailIsCommand: true,
                )
            case .offline:
                placeholder(
                    symbol: .boltSlash,
                    title: "Host unreachable",
                    detail: "Simulators appear once a pane is connected.",
                )
            }
        }
        .task(id: simulatorModel.generation) {
            await simulatorModel.poll(
                host: { [connection] in connection.target.host },
                ensure: { [store] in
                    await Self.firstConnectedMetadataClient(store)?.ensureSimulatorServer()
                },
            )
        }
        // A SECOND task, keyed on readiness: the device poll starts only once there is a server to
        // ask, and restarts if the endpoint moves. Folding it into the ensure loop would tie the
        // list's refresh rate to the server-boot retry rate, and those want opposite cadences.
        .task(id: simulatorReadyKey) {
            guard case .ready = simulatorModel.phase else { return }
            await simulatorModel.watchDevices()
        }
        // The two `.task`s above stop themselves when this surface goes away; the STREAM does not,
        // because the model holding it is `@State` on the column and outlives the unmount by design.
        // Left alone it kept a host encoder and two websockets running for a panel nobody could see —
        // see ``SimulatorSidebarModel/park()`` for what that cost. Appearing re-opens it, which is
        // also what makes coming back to the tab land on the device rather than on the list.
        .onAppear { simulatorModel.resume() }
        .onDisappear { simulatorModel.park() }
    }

    /// Changes when the server's ADDRESS does, not merely when the phase object is rebuilt — so a
    /// respawn on a new port restarts the device poll and an identical re-render does not.
    private var simulatorReadyKey: String {
        guard case let .ready(host, port) = simulatorModel.phase else { return "" }
        return "\(host):\(port)"
    }

    @ViewBuilder
    private var simulatorReadyContent: some View {
        if simulatorModel.selection != nil {
            SimulatorStageView(model: simulatorModel)
        } else {
            SimulatorDeviceList(model: simulatorModel)
        }
    }

    /// The centered spinner surface — the code-server boot and the pre-push projectKey wait share
    /// it (both are short-lived, both resolve on their own).
    private func waiting(_ label: String) -> some View {
        VStack(spacing: Slate.Metric.space2) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A centered empty-state: dim glyph, one-line title, secondary detail (optionally set in the
    /// instrument face for a copyable shell command).
    private func placeholder(
        symbol: SFSymbol, title: String, detail: String, detailIsCommand: Bool = false,
    ) -> some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.display * 0.6))
                .foregroundStyle(Slate.Text.tertiary)
            Text(title)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(detail)
                .font(
                    detailIsCommand
                        ? Slate.Typeface.instrument(Slate.Typeface.footnote)
                        : .system(size: Slate.Typeface.footnote),
                )
                .foregroundStyle(Slate.Text.secondary)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding(Slate.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One ensure round: verb 18 through whichever pane carries a live metadata channel (resolved
    /// per call, like the host-info/vitals fetchers — survives pane churn/reconnects). `nil` when no
    /// pane is connected (→ `.offline`, and the loop keeps polling). A round that reaches a host
    /// which HAS code-server also pushes the client's terminal-font spec (verb 20) — the seed has
    /// to land before the workbench reads its settings, so the push rides the starting rounds
    /// rather than waiting for `.ready`. An old host's `.unsupportedVerb` is silently ignored (the
    /// editor keeps the seeded defaults).
    ///
    /// Two things it deliberately does NOT do. It does not push to an `.unavailable` host: the
    /// poll keeps running every ~3.6 s while the panel is open, and patching a settings file for a
    /// workbench that will never boot is pure churn. And it does not re-push a spec identical to
    /// the last one it sent on this round-trip path — the host no-ops such a write, but the
    /// round-trip itself still occupies the metadata queue behind real work.
    private static func ensureEndpoint(
        projectRoot: String, store: WorkspaceStore, preferences: PreferencesStore?,
    ) async -> MetadataCodec.ServiceEndpoint? {
        guard let client = firstConnectedMetadataClient(store) else { return nil }
        let endpoint = await client.ensureCodeServer(projectRoot: projectRoot)
        if let terminal = preferences?.terminal {
            let spec = CodeFontSync.spec(terminal: terminal)
            if CodeFontSync.shouldPush(endpoint: endpoint, spec: spec, lastSent: lastPushedFontSpec) {
                lastPushedFontSpec = spec
                await client.syncCodeFont(spec)
            }
        }
        return endpoint
    }

    /// The spec the last ensure round pushed — the dedupe key above. Static because the poll is
    /// restarted per project/reload and the settings file it writes is host-global anyway; a
    /// project switch must not re-push a spec the host already has.
    @MainActor private static var lastPushedFontSpec: MetadataCodec.CodeFontSpec?

    private static func firstConnectedMetadataClient(_ store: WorkspaceStore) -> MetadataClient? {
        for id in store.tree.activeSession?.allPaneIDs() ?? [] {
            if let client = (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient {
                return client
            }
        }
        return nil
    }
}
#endif
