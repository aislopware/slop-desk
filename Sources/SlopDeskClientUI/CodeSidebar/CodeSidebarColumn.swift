// CodeSidebarColumn — the RIGHT sidebar: the project-scoped embedded VS Code (code-server in a
// pooled WKWebView). Project-scoped means the ACTIVE pane picks the project (its host-pushed
// `projectKey` — the same key the left panel's sections group by), and every pane of that project
// shares the ONE workbench opened at the project root; focusing a pane of another project swaps the
// warm webview for THAT project back in (see `CodeSidebarWebViewPool`). A project's FIRST-EVER
// workbench is gated behind an explicit open (``CodeOpenGate`` — user-directed 2026-08-07): focus
// changes are free, and the boot is paid only when asked for. The admission persists
// (`Defaults[.openedCodeProjects]`), so a relaunch boots straight back into known projects.
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
        case android
        case desktop
    }

    @State private var surfaceTab: SurfaceTab = .code
    @State private var simulatorModel = SimulatorSidebarModel()
    /// The Android surface's own model. A FOURTH tab rather than a second half of Simulators: the two
    /// share not one byte of protocol — `baguette`'s websocket against `scrcpy` over `adb`, AVC
    /// against Annex-B, JSON envelopes against packed control messages — and folding them into one
    /// surface would mean a list whose rows dispatch on platform and a stage whose every control has
    /// two implementations. They are two device sets that happen to look alike in a sidebar.
    @State private var androidModel = AndroidSidebarModel()
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

    var body: some View {
        // THE PANEL ISLAND (user-directed 2026-08-07, islands round — reversing the same round's
        // earlier flat-panel call): the whole panel is a SECOND glass island beside the terminal's,
        // with the tab strip INSIDE the card — the tabs belong to the island they switch, and a
        // strip left out on the chrome floor read as an orphaned band. Same anatomy as the terminal
        // island: the glass surface, the forced glass scheme (so the strip's chips, inks and every
        // surface below resolve against the glass, not the OS appearance), the continuous island
        // radius, and NO border ring or shadow (JetBrains ships island borders equal to the island
        // fill — the field gap and radius are the whole separation). NO leading margin: the
        // terminal island's trailing margin (plus the 1px divider gap) already IS the channel
        // between the two cards, and paying a second margin here doubled it — "the two islands are
        // too far apart" (user-directed 2026-08-07). One margin per gutter keeps every field
        // channel in the window the same width.
        VStack(spacing: 0) {
            strip
            surfaceArea
        }
        .background(Slate.Surface.terminal)
        .environment(\.colorScheme, Slate.glassColorScheme)
        .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusIsland, style: .continuous))
        .padding([.top, .bottom, .trailing], Slate.Metric.islandMargin)
        // The one window field behind the island — the same floor every column paints.
        .background(Slate.Surface.field)
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

    /// The surface region, filling the island below its strip.
    private var surfaceArea: some View {
        Group {
            // A bare switch: the surfaces carry no animation of their own — whatever motion the
            // swap has rides the `selectSurface` transaction, exactly like the pre-removal
            // inspector's content switch under its `withAnimation` tab write.
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
    }

    /// The panel's OWN top strip (user-directed: the tabs belong to the panel, over the panel,
    /// never over the terminal). Tab plates lead, actions trail (the otty strip layout); the row
    /// is CENTERED in the strip band (user-directed 2026-08-03, overriding the earlier
    /// titlebar-row top-anchor). Every tab shows its MARK AND ITS NAME while the panel is wide
    /// enough for that, and gives up the names a rung at a time when it is not — see `tabs(labelling:)`
    /// and ``PanelTabPlate``. The reload plate rides only the Code surface (Desktop has nothing to
    /// reload); the far trailing corner is the panel's HIDE toggle (user-directed 2026-08-03 —
    /// moved here from the terminal's titlebar, which now carries only the collapsed-state reopen).
    /// A tab click animates through ONE `withAnimation(standard)` transaction around the state
    /// write — the pre-removal inspector's choreography (`InspectorColumn.tabButton`, resurrected
    /// user-directed 2026-08-03). The transaction carries the plate fill, the reload plate's
    /// arrival, and the surface swap together; there are NO per-view `.animation` modifiers on
    /// this path (two redesigns that added them were both rejected).
    private func selectSurface(_ tab: SurfaceTab) {
        withAnimation(Slate.Anim.standard) { surfaceTab = tab }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            // THE WIDTH LADDER. Four tabs carrying a mark and a word want ~330pt, and the panel's
            // minimum (`codeSidebarMinWidth`, 380) leaves the tabs about 310 once the action plates
            // are paid for — so a panel dragged narrow has to give something up. `ViewThatFits` picks
            // the first rung that fits: every tab named, then only the selected one, then none. It
            // degrades a rung at a time rather than truncating, because a tab reading "Simulat…" has
            // stopped saying what it switches to, while a mark alone still does.
            ViewThatFits(in: .horizontal) {
                tabs(labelling: .all)
                tabs(labelling: .selectedOnly)
                tabs(labelling: .none)
            }
            Spacer(minLength: 0)
            switch surfaceTab {
            case .code:
                // The reload plate rides only a MOUNTED workbench — behind the open gate there is
                // nothing to reload, and a bump of the poll generation would boot the very thing
                // the gate exists to defer.
                if let root = activeProjectRoot, chrome.openedCodeProjects.contains(root) {
                    PlateIconButton(symbol: .arrowClockwise) {
                        CodeSidebarWebViewPool.shared.reload(projectRoot: root)
                        model.requestReload()
                    }
                    .help("Reload the workbench")
                }
            case .simulators:
                // No back control here: leaving a device is navigation within the surface, and it
                // now sits beside the device's own name in `SimulatorDeviceHeader` — where every
                // other split view in the app puts it. This strip stays surface-level verbs only.
                PlateIconButton(symbol: .arrowClockwise) { simulatorModel.requestReload() }
                    .help("Reload the simulator list")
            case .android:
                PlateIconButton(symbol: .arrowClockwise) { androidModel.requestReload() }
                    .help("Reload the device list")
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

    /// One rung of the strip's width ladder — how many tabs get to say their name.
    private enum TabLabelling {
        case all
        case selectedOnly
        case none
    }

    /// The four surface tabs, as their own GROUP on a wider gap than the action plates trailing
    /// them: two lit plates side by side (the selected tab and the one under the pointer) touched at
    /// the strip's 2pt spacing and read as one long fill, where `space1` opens a channel between them
    /// while still holding the tabs closer to each other than to anything else.
    ///
    /// The marks are the app's ordinary vocabulary except for Android's, which is a drawn path
    /// because no icon set ships one (``AndroidRobotMark``). Since the two platform tabs are now
    /// named "Simulators" and "Emulators" — one letter apart, and both true of the other platform —
    /// the logo is the only thing in the tab that says WHICH platform, so it is load-bearing rather
    /// than decorative. Desktop's glyph is `display`, the app's existing GUI-surface vocabulary
    /// (`macwindow` read as a blob at strip size — user-rejected).
    private func tabs(labelling: TabLabelling) -> some View {
        func names(_ tab: SurfaceTab) -> Bool {
            switch labelling {
            case .all: true
            case .selectedOnly: surfaceTab == tab
            case .none: false
            }
        }
        return HStack(spacing: Slate.Metric.space1) {
            PanelTabPlate(
                // The folder register (user-directed 2026-08-03), not a lone document — the tab
                // opens the whole project tree. `folder` also sidesteps the deprecated `doc`
                // family (SF6 renamed it wholesale; the new constants outrun the package floor).
                symbol: .folder, label: "Files", selected: surfaceTab == .code,
                showsLabel: names(.code),
            ) { selectSurface(.code) }
                .help("Files — the project's embedded editor")
            // Simulators sits beside Files because it is the other REAL surface — a live host
            // resource, not the announced-but-empty Desktop.
            PanelTabPlate(
                symbol: .appleLogo, label: "Simulators", selected: surfaceTab == .simulators,
                showsLabel: names(.simulators),
            ) { selectSurface(.simulators) }
                .help("Simulators — the host's iOS Simulator devices")
            // "Emulators" names the tab (user-directed 2026-08-05) and the help text carries the
            // rest: the surface also lists attached hardware, which no emulator is.
            PanelTabPlate(
                mark: .android, label: "Emulators", selected: surfaceTab == .android,
                showsLabel: names(.android),
            ) { selectSurface(.android) }
                .help("Emulators — the host's Android emulators and attached devices")
            PanelTabPlate(
                symbol: .display, label: "Desktop", selected: surfaceTab == .desktop,
                showsLabel: names(.desktop),
            ) { selectSurface(.desktop) }
                .help("Desktop — the host's window surface")
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
                    // The veil covers a workbench that is GLASS-dark: it paints the glass canvas
                    // under the forced glass scheme so its spinner/label read on it — a chrome-lit
                    // veil here restores the black → white → workbench boot flash it exists to hide.
                    waiting("Opening workbench…")
                        .background(Slate.Surface.terminal)
                        .environment(\.colorScheme, Slate.glassColorScheme)
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
                    await Self.firstConnectedMetadataClient(store)?.ensureAndroidBridge()
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
#endif
