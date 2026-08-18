// CodePanelSurfaces — the RIGHT panel's four surfaces: the project-scoped embedded VS Code
// (code-server in a pooled WKWebView), the host's iOS Simulators, its Android devices, and the
// announced-but-empty Desktop.
//
// Project-scoped means the ACTIVE pane picks the project (its host-pushed `projectKey` — the same key
// the left panel's sections group by), and every pane of that project shares the ONE workbench opened
// at the project root; focusing a pane of another project swaps the warm webview for THAT project back
// in (see `CodeSidebarWebViewPool`). A project's FIRST-EVER workbench is gated behind an explicit open
// (``CodeOpenGate`` — user-directed 2026-08-07): focus changes are free, and the boot is paid only when
// asked for. The admission persists (`Defaults[.openedCodeProjects]`), so a relaunch boots straight
// back into known projects.
//
// THE PANEL'S CHROME IS NOT HERE, AND THAT IS WHY THE SURFACES CROSS. The strip of tabs over these
// surfaces, the width ladder that decides how many of them say their name, and the rail the collapsed
// panel leaves behind are AppKit now (`SlopDeskMacUI`: `MacPanelStrip`, `MacPanelTabGroup`,
// `MacPanelRail`), mounted as this view's SIBLING under `MacCodePanelColumn` — docs/56 stage D. What
// is left here is the four surfaces and the host conversations that keep them alive, which is why the
// three MODELS are handed in rather than held: the strip's reload plate drives them from outside this
// tree. The phone will hang its own chrome — a tab bar, not a strip — off the same three models.
//
// How the surfaces are HOUSED stays each platform's own business. On the Mac the column is a plain
// `NSSplitViewItem` (a THIRD column beside navigator | content — never `.inspector`, whose collapse
// unmounts the content and would kill the webview's layout). While collapsed the split item unparents
// this view, SwiftUI cancels the `.task`, and the poll loop stops — the code-server is only ever
// ensured when the panel is open, on either platform, because the ensure rides the mount.

import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

package struct CodePanelSurfaces: View {
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
    /// The three surface models, OWNED BY THE COLUMN rather than held here as `@State`. The strip's
    /// reload plate is AppKit and stands outside this tree, so the thing it reloads cannot live inside
    /// it — and the parking rules below (`resume`/`park`) already depended on these outliving the
    /// unmount, which `@State` gave for the wrong reason.
    let model: CodeSidebarModel
    let simulatorModel: SimulatorSidebarModel
    let androidModel: AndroidSidebarModel

    package init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        preferences: PreferencesStore?, model: CodeSidebarModel,
        simulatorModel: SimulatorSidebarModel, androidModel: AndroidSidebarModel,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.preferences = preferences
        self.model = model
        self.simulatorModel = simulatorModel
        self.androidModel = androidModel
    }

    /// The panel surface the strip's tab row selects — read from the shared chrome model
    /// (``PanelSurface``), not from local state: the collapsed panel's RAIL renders the same four
    /// tabs and must select the same thing.
    private var surfaceTab: PanelSurface { chrome.panelSurface }
    /// Where the Simulators surface's reports go — the window's own notification stack, so this panel
    /// speaks in the same card as everything else that has something to say. See ``announce(_:isFailure:)``.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

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

    package var body: some View {
        // NO rule under the strip above (user-directed 2026-08-09, reversing 2026-08-04). It was there
        // because the ground band used to end in an abrupt tone change against the workbench's own tab
        // strip — two mismatched grays stacked with nothing between them. That reason has since gone:
        // the panel is one cream from the strip through the canvas, so the two sides of that seam are
        // the same colour and there is nothing left to separate. What the rule did instead was land a
        // second horizontal line a few pixels off the edge the embedded workbench draws for itself,
        // and a doubled seam is what you saw.
        //
        // A bare switch: the surfaces carry no animation of their own — whatever motion the swap has
        // rides the transaction the strip's tab click opens, one framework over.
        Group {
            switch surfaceTab {
            case .code:
                surface
            case .simulators:
                simulatorSurface
            case .android:
                androidSurface
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.field)
        // THE COLUMN'S CONTENT LEAVES BEFORE ITS WIDTH DOES (user-reported 2026-08-09: the collapse
        // read as rough). A panel closing is a width animation, and everything standing in it —
        // an embedded workbench, a device stage, a strip of tabs — gets re-laid-out at every
        // intermediate width on the way out. That reflow is the roughness; it is not the slide.
        // So the content fades first and the empty ground rides the rest of the slide out. Coming
        // back it is the mirror, arriving as the column lands, which is the same contract the
        // titlebar strip and the rail keep — one gesture, one clock.
        .opacity(chrome.codeSidebarCollapsed ? 0 : 1)
        .animation(
            chrome.codeSidebarCollapsed
                ? Slate.Anim.fadeOut
                : Slate.Anim.reveal.delay(Slate.Anim.columnSlideDuration * 0.55),
            value: chrome.codeSidebarCollapsed,
        )
        // A LIVE font-prefs change while the panel is open re-syncs immediately (the workbench's
        // settings watcher applies it without a reload). The ensure-round sync below covers the
        // panel-open path; this covers Settings edits mid-session. Best-effort, reply ignored.
        .onChange(of: fontSpec) { _, spec in
            guard let spec, let client = store.firstConnectedMetadataClient else { return }
            // Records the push too, so the next ensure round does not re-send what just landed.
            Self.lastPushedFontSpec = spec
            Task { await client.syncCodeFont(spec) }
        }
    }

    /// The workbench surface below the strip — phase-switched per the active project. A root the
    /// user has never opened renders the OPEN GATE instead of mounting anything: no ensure poll,
    /// no proxy bind, no webview — a project switch costs nothing until the workbench is asked
    /// for (user-directed 2026-08-07). Once admitted (`chrome.openedCodeProjects` — persisted, so
    /// relaunches skip the gate too) the root keeps the old behavior: returning to it is the warm
    /// swap it always was.
    private var surface: some View {
        Group {
            if let root = activeProjectRoot, !chrome.openedCodeProjects.contains(root) {
                CodeOpenGate(projectRoot: root) { chrome.openCodeProject(root) }
            } else if let root = activeProjectRoot {
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
                // The provision script, not `brew install`: the panel is written against the
                // `code-server` version pinned in `ThirdParty/tools/tools.lock`, and the Homebrew
                // formula froze at 4.112 (below the Code 1.121 floor this panel needs) before being
                // deprecated outright. Sending someone to `brew` here hands them the broken one.
                detail: "bash ThirdParty/tools/provision.sh",
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
                        .background(Slate.Surface.field)
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
        // A ZSTACK, not a `Group`: a phase change swaps one full-surface state for another, and while
        // the two overlap a `Group` inside the column's `VStack` lays them out as two stacked bands —
        // the outgoing state visibly squeezing the incoming one for the length of the fade.
        ZStack {
            switch simulatorModel.phase {
            case .ready:
                simulatorReadyContent
            case .starting:
                waiting("Starting simulator server…")
            case .unavailable:
                placeholder(
                    symbol: .iphoneSlash,
                    title: "baguette not found on host",
                    detail: "bash ThirdParty/tools/provision.sh",
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
        // Keyed on WHICH phase, not on the phase value: a `.ready` server that respawns on a new port
        // is the same surface and must not blink, while server-boot → devices is a real change of
        // subject and cuts hard without this.
        .animation(Slate.Anim.standard, value: simulatorPhaseKey)
        .task(id: simulatorModel.generation) {
            await simulatorModel.poll(
                host: { [connection] in connection.target.host },
                ensure: { [store] in
                    await store.firstConnectedMetadataClient?.ensureSimulatorServer()
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
        // Every report the panel makes leaves through the app's OWN notification (user-directed
        // 2026-08-04). The panel used to draw its own: a bordered capsule floating over the stage and a
        // second, differently-shaped one ruled into the list — two bespoke alert chromes for events the
        // window already has one card for, and the capsule read as an alert from another application.
        //
        // Here rather than on either surface, because the surfaces come and go under the message: the
        // "no longer running" verdict sets the text and clears the selection in one write, so a listener
        // on the stage would be torn down in the same transaction that fired it.
        .onChange(of: simulatorModel.failure) { _, text in announce(text, isFailure: true) }
        .onChange(of: simulatorModel.notice) { _, text in announce(text, isFailure: false) }
    }

    /// One card, replaced rather than stacked (the fixed id is the warp `object_id` discipline the other
    /// window-level notices use): these are reports about ONE panel, and three of them queued behind each
    /// other would outlive the thing they describe.
    ///
    /// The device is the SUBJECT and the sentence is the detail, not the other way round. A headline is
    /// one middle-truncated line, and every one of these messages is longer than that line — put the
    /// sentence there and the reader loses its middle, which is where the verb is.
    private func announce(_ text: String?, isFailure: Bool) {
        guard let text, !text.isEmpty else { return }
        overlayCoordinator?.pushToast(Toast(
            id: "simulator",
            flavor: isFailure ? .error : .success,
            // An event at a device, not an agent's lifecycle — and with no pane to jump to, so the card
            // renders as a plain notice rather than a door.
            source: .command,
            title: simulatorSubject,
            body: text,
            headline: simulatorSubject,
        ))
    }

    /// The device the report is about, or the panel itself when there is none — a report that arrives
    /// after the selection is cleared still has to say where it came from.
    private var simulatorSubject: String {
        guard let udid = simulatorModel.selection,
              let device = simulatorModel.devices.first(where: { $0.udid == udid })
        else { return "Simulators" }
        return device.name
    }

    /// Changes when the server's ADDRESS does, not merely when the phase object is rebuilt — so a
    /// respawn on a new port restarts the device poll and an identical re-render does not.
    private var simulatorReadyKey: String {
        guard case let .ready(host, port) = simulatorModel.phase else { return "" }
        return "\(host):\(port)"
    }

    /// Which of the four states is on screen, with the `.ready` payload deliberately dropped.
    private var simulatorPhaseKey: String {
        switch simulatorModel.phase {
        case .ready: "ready"
        case .starting: "starting"
        case .unavailable: "unavailable"
        case .offline: "offline"
        }
    }

    /// The list and the device are ONE surface at two depths, so the swap between them is a DRILL,
    /// not a cut. The stage always enters from the trailing side and leaves back that way, the list
    /// always from the leading side — one direction per view, which is what makes "in" and "out"
    /// legible without either of them knowing which way the last move went.
    ///
    /// The shift is a NUDGE, not a page slide. A full-width push of a live H.264 surface is 200ms of
    /// a video layer being composited across the panel to say something a few points of parallax
    /// already say; the depth cue is the offset's direction, and the fade carries the rest.
    ///
    /// A ZStack for the same reason the phase switch above uses one — mid-transition both views are
    /// mounted, and in a plain `if`/`else` the outgoing list would squeeze the arriving device.
    private var simulatorReadyContent: some View {
        ZStack {
            if simulatorModel.selection != nil {
                SimulatorStageView(model: simulatorModel)
                    .transition(Self.drill(from: Slate.Metric.space4))
            } else {
                SimulatorDeviceList(model: simulatorModel)
                    .transition(Self.drill(from: -Slate.Metric.space4))
            }
        }
    }

    // MARK: The Android surface

    /// The Android surface. Machine-scoped like Simulators — one `adb` server, one device set, no
    /// project to key on — and lazy for the same reason: the two `.task`s live here rather than on
    /// the column, so a user who never opens this tab never makes the host open its bridge at all.
    private var androidSurface: some View {
        ZStack {
            switch androidModel.phase {
            case .ready:
                androidReadyContent
            case .starting:
                waiting("Opening the Android bridge…")
            case .unavailable:
                placeholder(
                    symbol: .cableConnectorSlash,
                    title: "adb not found on host",
                    // `adb` is the one piece without which there is nothing to list. A missing
                    // `scrcpy-server` still lists and boots devices and reports itself when a mirror
                    // is asked for, which is where it can name itself against the action that wanted
                    // it — and it is committed to the repo now, so it is present in any checkout.
                    // The emulator is deliberately not provisioned (system images are gigabytes
                    // behind a licence accept), so a host that wants AVDs still needs its own SDK.
                    detail: "bash ThirdParty/tools/provision.sh",
                    detailIsCommand: true,
                )
            case .offline:
                placeholder(
                    symbol: .boltSlash,
                    title: "Host unreachable",
                    detail: "Devices appear once a pane is connected.",
                )
            }
        }
        // Keyed on WHICH phase, not on the phase value: a bridge that rebinds on a new port is the
        // same surface and must not blink.
        .animation(Slate.Anim.standard, value: androidPhaseKey)
        .task(id: androidModel.generation) {
            await androidModel.poll(
                host: { [connection] in connection.target.host },
                ensure: { [store] in
                    await store.firstConnectedMetadataClient?.ensureAndroidBridge()
                },
            )
        }
        .task(id: androidReadyKey) {
            guard case .ready = androidModel.phase else { return }
            await androidModel.watchDevices()
        }
        // The tasks above stop themselves when this surface goes away; the MIRROR does not, because
        // the model holding it is `@State` on the column. Left alone it would keep the DEVICE's
        // hardware encoder running for a panel nobody can see — see ``AndroidSidebarModel/park()``.
        .onAppear { androidModel.resume() }
        .onDisappear { androidModel.park() }
        // Every report leaves through the app's own notification, for the reason the simulator
        // surface records: the surfaces come and go under the message, so a listener on the stage
        // would be torn down in the same transaction that fired it.
        .onChange(of: androidModel.failure) { _, text in announceAndroid(text, isFailure: true) }
        .onChange(of: androidModel.notice) { _, text in announceAndroid(text, isFailure: false) }
    }

    private var androidReadyContent: some View {
        ZStack {
            if androidModel.selection != nil {
                AndroidStageView(model: androidModel)
                    .transition(Self.drill(from: Slate.Metric.space4))
            } else {
                AndroidDeviceList(model: androidModel)
                    .transition(Self.drill(from: -Slate.Metric.space4))
            }
        }
    }

    /// Its own toast id, not the simulator panel's: the two surfaces can both have something to say
    /// about different devices, and sharing an id would have one panel's report replace the other's.
    private func announceAndroid(_ text: String?, isFailure: Bool) {
        guard let text, !text.isEmpty else { return }
        overlayCoordinator?.pushToast(Toast(
            id: "android",
            flavor: isFailure ? .error : .success,
            source: .command,
            title: androidSubject,
            body: text,
            headline: androidSubject,
        ))
    }

    /// The device the report is about, or the panel itself when there is none — a report that arrives
    /// after the selection is cleared still has to say where it came from.
    private var androidSubject: String {
        androidModel.selectedDevice?.name ?? "Android"
    }

    private var androidReadyKey: String {
        guard case let .ready(host, port) = androidModel.phase else { return "" }
        return "\(host):\(port)"
    }

    private var androidPhaseKey: String {
        switch androidModel.phase {
        case .ready: "ready"
        case .starting: "starting"
        case .unavailable: "unavailable"
        case .offline: "offline"
        }
    }

    /// Enter from `shift`, leave back to it — symmetric, because a view's side of the hierarchy does
    /// not change with the direction of travel.
    private static func drill(from shift: CGFloat) -> AnyTransition {
        .offset(x: shift).combined(with: .opacity)
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
        guard let client = store.firstConnectedMetadataClient else { return nil }
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
}

/// The open gate — what a project shows before its first-ever workbench open
/// (user-directed 2026-08-07). Same anatomy as the panel's placeholder surfaces (dim glyph, one
/// primary line, secondary detail) so the panel keeps one empty-state voice; the detail line is the
/// FULL root in the instrument face because the title alone — the last path component — cannot tell
/// two same-named checkouts apart, and the gate is precisely the moment of deciding whether this is
/// the project worth booting an editor for. The button is the panel's one text-button idiom (the
/// stage views' "Try Again" plate) — hover lights the fill a rung, the press drops it back.
private struct CodeOpenGate: View {
    let projectRoot: String
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .folder)
                .font(.system(size: Slate.Typeface.display * 0.6))
                .foregroundStyle(Slate.Text.tertiary)
            Text(URL(fileURLWithPath: projectRoot).lastPathComponent)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(projectRoot)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: open) {
                Text("Open Editor")
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .padding(.horizontal, Slate.Metric.space3)
                    .padding(.vertical, Slate.Metric.space1)
                    .contentShape(.rect)
            }
            .buttonStyle(SlatePlateStyle { pressed in
                hovering && !pressed ? Slate.State.selected : Slate.Surface.raised
            })
            .onHover { hovering = $0 }
            .animation(Slate.Anim.smallFade, value: hovering)
            .padding(.top, Slate.Metric.space2)
        }
        .multilineTextAlignment(.center)
        .padding(Slate.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
