// CodePanelSurfaces — the RIGHT panel's four surfaces, on the PHONE.
//
// The project-scoped embedded VS Code (code-server in a pooled `WKWebView`), the host's iOS
// Simulators, its Android devices, and the announced-but-empty Desktop. Project-scoped means the
// ACTIVE pane picks the project (its host-pushed `projectKey` — the same key the left panel's sections
// group by), and every pane of that project shares the ONE workbench opened at the project root.
//
// iOS-ONLY SINCE docs/56 INCREMENT 51. The Mac's half is ``SlopDeskMacUI/MacCodePanelSurfaces``, in
// AppKit, and this file is the phone's renderer rather than a shared one — the split's ruling, applied
// to the last surface that was still drawn once for both. What is NOT duplicated is anything a reader
// reads or a state decides: every word here, and every phase→surface answer, is
// ``CodePanelPresentation``'s and is asked for rather than spelled.
//
// The two halves keep the same three things every increment since 19 has kept: the BINDING (`@Default`
// is a property wrapper whose whole point is that SwiftUI observes the read), the WIDGET, and the HUE
// (`SlopDeskSlate` depends on `SlopDeskClientCore`, so an ink cannot descend without becoming a cycle).
//
// How the surfaces are HOUSED stays each platform's own business. Here they sit under a full-screen
// cover with a bar over them (``PhonePanelSheet``); on the Mac they are a third split column.
//
// That difference used to be written here as a shared LIFETIME — "the code-server is only ever ensured
// while the panel is up, on either platform" — and it was wrong on both halves. The Mac's column is
// built once and collapse only fades it (`alphaValue`), so nothing there is ever unmounted and no
// `.task` is ever cancelled; and an ensure is not a lease anyway — ``CodeSidebarModel/poll`` RETURNS at
// `.ready`, so even a mounted panel stops asking, and a code-server outlives every client that ever
// ensured it. What the cover really cancels is a loop that had already finished.
//
// It is the RE-ENTRY the cover creates that had to be reconciled, and it is reconciled below the split
// rather than here: `poll` returns immediately when it is already settled on that root, so re-opening
// the cover shows the workbench it left instead of flashing the spinner over it. See that method's
// note. Anything about lifetime belongs there, in the one model both shells drive — a comment on one
// shell's renderer is exactly where a claim about the other shell goes stale unnoticed.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

package struct CodePanelSurfaces: View {
    let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    let connection: AppConnection
    /// The shared chrome state — which surface is selected, and which projects have been admitted.
    let chrome: WorkspaceChromeState
    /// The live preferences store (nil only in previews/automation shells) — the terminal font prefs
    /// the panel pushes host-side (verb 20) so the editor reads like the terminal beside it.
    let preferences: PreferencesStore?
    /// The three surface models, owned by whoever outlives the panel's presentation: a cover that is
    /// dismissed and re-opened must not re-list every device and re-boot every stream, and the parking
    /// rules (``SimulatorSidebarModel/park()``) already assume something outlives the surface tree.
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

    /// Where the device surfaces' reports go — the panel's own notification stack, so this surface
    /// speaks in the same card as everything else that has something to say.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    private var activePane: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the
    /// cwd fallback the sidebar sections tolerate (`paneProjectKey`). Ensuring on the transient
    /// pre-push cwd spawns a code-server for a root the project does not have (observed: the shell's
    /// start directory vs the git toplevel — two Node processes for one project, one stranded).
    private var activeProjectRoot: String? {
        guard let pane = activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the focused pane already has a SECTION identity but no host-pushed key yet — the first
    /// push is in flight. The mirror write re-renders this view the moment the key lands.
    private var awaitingProjectKey: Bool {
        guard let pane = activePane, activeProjectRoot == nil else { return false }
        return store.paneProjectKey(pane) != nil
    }

    /// The client's current terminal-font spec — recomputed whenever the observed terminal prefs
    /// change (the store is `@Observable`; reading `terminal` here subscribes the view).
    private var fontSpec: MetadataCodec.CodeFontSpec? {
        preferences.map { CodeFontSync.spec(terminal: $0.terminal) }
    }

    private var workbenchState: CodePanelWorkbenchState {
        CodePanelPresentation.workbench(
            phase: model.phase,
            activeProjectRoot: activeProjectRoot,
            openedProjects: chrome.openedCodeProjects,
            awaitingProjectKey: awaitingProjectKey,
        )
    }

    package var body: some View {
        // A bare switch: the surfaces carry no animation of their own — whatever motion the swap has
        // rides the transaction the bar's tab tap opens.
        Group {
            switch chrome.panelSurface {
            case .code: workbench
            case .simulators: simulators
            case .android: android
            case .desktop: PanelEmptyStateView(CodePanelPresentation.desktop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.field)
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

    // MARK: - The workbench

    /// The workbench surface. A root the reader has never opened renders the OPEN GATE and mounts
    /// nothing: no ensure poll, no proxy bind, no webview — a project switch costs nothing until the
    /// workbench is asked for (user-directed 2026-08-07). The admission persists
    /// (`Defaults[.openedCodeProjects]`), so a relaunch boots straight back into known projects.
    private var workbench: some View {
        Group {
            switch workbenchState {
            case let .gate(root):
                CodeOpenGate(projectRoot: root) { chrome.openCodeProject(root) }
            case let .workbench(root, url):
                webContent(projectRoot: root, url: url)
            case let .waiting(label):
                waiting(label)
            case let .empty(reading):
                PanelEmptyStateView(reading)
            }
        }
        // ⚠️ ONE task, OUTSIDE the switch. The states above are the phases the poll itself moves
        // through, so a `.task` per branch would cancel and restart the loop on every transition it
        // caused — a poll that re-ensures from scratch each time the host answers. Restarts happen on
        // a project switch or a manual reload and on nothing else, which is exactly what the key says.
        .task(id: pollKey) {
            guard let root = pollRoot else { return }
            await poll(projectRoot: root)
        }
    }

    /// The root the poll runs FOR, or `nil` for one that has not been admitted.
    ///
    /// Behind the gate there is nothing to ensure, and polling there would boot the very thing the
    /// gate exists to defer. The Mac's half decides it the same way, off the same two reads.
    private var pollRoot: String? {
        guard let root = activeProjectRoot, chrome.openedCodeProjects.contains(root) else { return nil }
        return root
    }

    /// The poll's identity: the root it ensures for and the reload generation.
    private var pollKey: String { "\(pollRoot ?? "")#\(model.generation)" }

    private func poll(projectRoot root: String) async {
        await model.poll(
            projectRoot: root,
            host: { connection.target.host },
            ensure: { [store, preferences] in
                await Self.ensureEndpoint(projectRoot: $0, store: store, preferences: preferences)
            },
            // Front the remote endpoint with the loopback relay: a secure browser context (no
            // insecure-context toast) on an origin that survives respawns. On bind failure the remote
            // address rides through — the ATS arbitrary-loads exception keeps that fallback loadable.
            localize: { host, port in
                await CodeSidebarProxyPool.shared.endpoint(host: host, port: port) ?? (host, port)
            },
        )
    }

    /// The mounted webview under its first-paint VEIL: the waiting surface stays on top from
    /// load-start until the main-frame navigation settles, then fades — without it the boot reads as
    /// black → WebKit's white canvas → workbench. The veil state is per-project and pooled with the
    /// webview, so a warm project swap mounts unveiled (no spurious spinner).
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

    // MARK: - The two device surfaces

    /// The Simulators surface. Machine-scoped, so unlike the workbench it has no project to key on and
    /// no waiting-for-`projectKey` state: one ensure loop, one device list, one live stream.
    ///
    /// The two `.task`s live on the surface rather than on the panel, which is what makes both LAZY:
    /// selecting another tab (or dismissing the cover) unmounts this and SwiftUI cancels them, so a
    /// reader who never opens this tab never causes the host to spawn a simulator server at all — and
    /// leaving the tab drops the device poll and the live stream rather than paying for them
    /// off-screen.
    private var simulators: some View {
        // A ZSTACK, not a `Group`: a phase change swaps one full-surface state for another, and while
        // the two overlap a `Group` inside a `VStack` lays them out as two stacked bands — the
        // outgoing state visibly squeezing the incoming one for the length of the fade.
        ZStack {
            switch CodePanelPresentation.simulators(simulatorModel.phase) {
            case .devices: SimulatorSurface(model: simulatorModel)
            case let .waiting(label): waiting(label)
            case let .empty(reading): PanelEmptyStateView(reading)
            }
        }
        // Keyed on WHICH phase, not on the phase value: a `.ready` server that respawns on a new port
        // is the same surface and must not blink, while server-boot → devices is a real change of
        // subject and cuts hard without this.
        .animation(Slate.Anim.standard, value: CodePanelPresentation.phaseKey(simulatorModel.phase))
        .task(id: simulatorModel.generation) {
            await simulatorModel.poll(
                host: { connection.target.host },
                ensure: { [store] in
                    await store.firstConnectedMetadataClient?.ensureSimulatorServer()
                },
            )
        }
        // A SECOND task, keyed on readiness: the device poll starts only once there is a server to
        // ask, and restarts if the endpoint moves. Folding it into the ensure loop would tie the
        // list's refresh rate to the server-boot retry rate, and those want opposite cadences.
        .task(id: CodePanelPresentation.readyKey(simulatorModel.phase)) {
            guard case .ready = simulatorModel.phase else { return }
            await simulatorModel.watchDevices()
        }
        // The two `.task`s above stop themselves when this surface goes away; the STREAM does not,
        // because the model holding it outlives the unmount by design. Left alone it kept a host
        // encoder and two websockets running for a panel nobody could see.
        .onAppear { simulatorModel.resume() }
        .onDisappear { simulatorModel.park() }
        .onChange(of: simulatorModel.failure) { _, text in
            announce(
                text,
                isFailure: true,
                id: CodePanelPresentation.simulatorToastID,
                subject: simulatorSubject,
            )
        }
        .onChange(of: simulatorModel.notice) { _, text in
            announce(
                text,
                isFailure: false,
                id: CodePanelPresentation.simulatorToastID,
                subject: simulatorSubject,
            )
        }
    }

    /// The Android surface. Machine-scoped like Simulators — one `adb` server, one device set, no
    /// project to key on — and lazy for the same reason.
    private var android: some View {
        ZStack {
            switch CodePanelPresentation.android(androidModel.phase) {
            case .devices: AndroidSurface(model: androidModel)
            case let .waiting(label): waiting(label)
            case let .empty(reading): PanelEmptyStateView(reading)
            }
        }
        .animation(Slate.Anim.standard, value: CodePanelPresentation.phaseKey(androidModel.phase))
        .task(id: androidModel.generation) {
            await androidModel.poll(
                host: { connection.target.host },
                ensure: { [store] in
                    await store.firstConnectedMetadataClient?.ensureAndroidBridge()
                },
            )
        }
        .task(id: CodePanelPresentation.readyKey(androidModel.phase)) {
            guard case .ready = androidModel.phase else { return }
            await androidModel.watchDevices()
        }
        .onAppear { androidModel.resume() }
        .onDisappear { androidModel.park() }
        .onChange(of: androidModel.failure) { _, text in
            announce(
                text,
                isFailure: true,
                id: CodePanelPresentation.androidToastID,
                subject: androidSubject,
            )
        }
        .onChange(of: androidModel.notice) { _, text in
            announce(
                text,
                isFailure: false,
                id: CodePanelPresentation.androidToastID,
                subject: androidSubject,
            )
        }
    }

    // MARK: - What a device surface reports

    /// One card per surface, replaced rather than stacked (the fixed id is the `object_id` discipline
    /// the other window-level notices use): these are reports about ONE panel, and three of them
    /// queued behind each other would outlive the thing they describe.
    ///
    /// Here rather than on either surface, because the surfaces come and go under the message: the
    /// "no longer running" verdict sets the text and clears the selection in one write, so a listener
    /// on the stage would be torn down in the same transaction that fired it.
    ///
    /// The device is the SUBJECT and the sentence is the detail, not the other way round. A headline
    /// is one middle-truncated line, and every one of these messages is longer than that line — put
    /// the sentence there and the reader loses its middle, which is where the verb is.
    private func announce(_ text: String?, isFailure: Bool, id: String, subject: String) {
        guard let text, !text.isEmpty else { return }
        overlayCoordinator?.pushToast(Toast(
            id: id,
            flavor: isFailure ? .error : .success,
            // An event at a device, not an agent's lifecycle — and with no pane to jump to, so the
            // card renders as a plain notice rather than a door.
            source: .command,
            title: subject,
            body: text,
            headline: subject,
        ))
    }

    private var simulatorSubject: String {
        guard let udid = simulatorModel.selection,
              let device = simulatorModel.devices.first(where: { $0.udid == udid })
        else { return CodePanelPresentation.simulatorFallbackSubject }
        return device.name
    }

    private var androidSubject: String {
        androidModel.selectedDevice?.name ?? CodePanelPresentation.androidFallbackSubject
    }

    // MARK: - The two shared surfaces

    /// The centred spinner — the code-server boot, the two service boots and the pre-push `projectKey`
    /// wait share it (all short-lived, all resolve on their own).
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

    // MARK: - The ensure round

    /// One ensure round: verb 18 through whichever pane carries a live metadata channel (resolved per
    /// call, like the host-info/vitals fetchers — survives pane churn/reconnects). `nil` when no pane
    /// is connected (→ `.offline`, and the loop keeps polling). A round that reaches a host which HAS
    /// code-server also pushes the client's terminal-font spec (verb 20) — the seed has to land before
    /// the workbench reads its settings, so the push rides the starting rounds rather than waiting for
    /// `.ready`. An old host's `.unsupportedVerb` is silently ignored (the editor keeps the seeded
    /// defaults).
    ///
    /// Two things it deliberately does NOT do. It does not push to an `.unavailable` host: the poll
    /// keeps running every ~3.6 s while the panel is open, and patching a settings file for a
    /// workbench that will never boot is pure churn. And it does not re-push a spec identical to the
    /// last one it sent on this round-trip path — the host no-ops such a write, but the round trip
    /// itself still occupies the metadata queue behind real work.
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
    /// restarted per project/reload and the settings file it writes is host-global anyway; a project
    /// switch must not re-push a spec the host already has.
    @MainActor private static var lastPushedFontSpec: MetadataCodec.CodeFontSpec?
}

// MARK: - The empty state, and the gate

/// The panel's centred empty state — dim glyph, one-line title, secondary detail (optionally set in
/// the instrument face for a copyable shell command).
///
/// One view for all seven situations, off one record, because the panel has ONE empty-state voice
/// (MERIDIAN C3). The AppKit half is ``SlopDeskMacUI/MacPanelEmptyStateView`` and reads the same
/// record; what differs is the framework and nothing else.
struct PanelEmptyStateView: View {
    let reading: PanelEmptyState

    init(_ reading: PanelEmptyState) { self.reading = reading }

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemName: reading.systemImage)
                .font(.system(size: Slate.Typeface.display * 0.6))
                .foregroundStyle(Slate.Text.tertiary)
            Text(reading.title)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(reading.detail)
                .font(
                    reading.detailIsCommand
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
}

/// The open gate — what a project shows before its first-ever workbench open (user-directed
/// 2026-08-07). Same anatomy as the empty states so the panel keeps one voice; the detail line is the
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
            Image(systemName: CodeOpenGateReading.systemImage)
                .font(.system(size: Slate.Typeface.display * 0.6))
                .foregroundStyle(Slate.Text.tertiary)
            Text(CodeOpenGateReading.title(projectRoot: projectRoot))
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(projectRoot)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: open) {
                Text(CodeOpenGateReading.openTitle)
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
