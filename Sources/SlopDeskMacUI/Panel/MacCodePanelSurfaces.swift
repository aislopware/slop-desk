// MacCodePanelSurfaces — the RIGHT panel's four surfaces, in AppKit (docs/56 stage D, increment 51).
//
// The workbench (code-server in a pooled `WKWebView`), the host's iOS Simulators, its Android devices,
// and the announced-but-empty Desktop. The strip of tabs over them is this view's SIBLING under
// ``MacCodePanelColumn``; what is here is the surfaces and the host conversations that keep them
// alive.
//
// WHAT EACH SURFACE SAYS IS NOT HERE — it is ``CodePanelPresentation``, one floor down, because the
// phone draws the same four surfaces on its own layout and the words are not a fact about either
// drawing. What IS here is every part of the answer that is a framework: which `NSView` a state
// mounts, and — the load-bearing half — the LIFETIME of the loops, because that is precisely where
// SwiftUI and AppKit disagree.
//
// ## The loops, which are the reason this file is not a switch statement
//
// The SwiftUI original hung five `.task(id:)`s off the surfaces and got their whole lifecycle for
// free: a surface leaving cancelled its loops, and an id change restarted them. AppKit gives none of
// that, so the rule is written out — `keyed(_:on:run:)` below is that `.task(id:)`, and every surface
// swap cancels what it owned. Getting it wrong is not a crash: it is a host encoder and two sockets
// left running for a panel nobody can see, which is exactly the bill ``SimulatorSidebarModel/park()``
// exists to stop, or a poll that never restarts after a project switch and a panel stuck on a spinner.
//
// ## Why the two device surfaces are still hosted
//
// `SimulatorStageView`, `SimulatorDeviceList`, `AndroidStageView` and `AndroidDeviceList` are ~4,100
// lines of SwiftUI in `SlopDeskClientUI`, and they cross on their own schedule — the panel's ledger
// entry counted the 632 lines of surface switching and missed them (docs/56, increment 51). Until they
// do, they are mounted through the one factory named for them, and this file's `SlopDeskClientUI`
// import says so and nothing more.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // the two DEVICE surfaces, until they cross — nothing else
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacCodePanelSurfaces: NSViewController {
    private let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// The live preferences store (nil only in previews/automation shells) — the terminal font prefs
    /// the panel pushes host-side (verb 20) so the editor reads like the terminal beside it.
    private let preferences: PreferencesStore?
    /// Where a device surface's reports go — the window's own notification stack, so the panel speaks
    /// in the same card as everything else that has something to say.
    private let overlay: OverlayCoordinator?

    /// The three surface models, owned by ``MacCodePanelColumn`` because the strip's reload plate
    /// drives them from outside this tree.
    private let model: CodeSidebarModel
    private let simulatorModel: SimulatorSidebarModel
    private let androidModel: AndroidSidebarModel

    /// What is mounted, and under which identity. The identity is what makes an observation callback
    /// that changed nothing cost nothing — a surface rebuilt on every store write would tear down the
    /// workbench several times a second.
    private var mountedKey = ""
    private var mountedChild: NSViewController?

    /// The five loops, by the key that owns each. A `nil` key means "no loop should be running".
    private var loops: [LoopID: (key: String, task: Task<Void, Never>)] = [:]

    /// The last text each device model reported, so an observation that re-fires without a new report
    /// does not push the same card again.
    private var lastSimulatorReport: (failure: String?, notice: String?) = (nil, nil)
    private var lastAndroidReport: (failure: String?, notice: String?) = (nil, nil)

    /// Which loop a key belongs to. Named rather than an array index because four of the five are
    /// paired and the pairs must not be able to cancel each other.
    private enum LoopID: CaseIterable {
        case codePoll
        case simulatorEnsure
        case simulatorWatch
        case androidEnsure
        case androidWatch
    }

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        preferences: PreferencesStore?, overlay: OverlayCoordinator?,
        model: CodeSidebarModel, simulatorModel: SimulatorSidebarModel,
        androidModel: AndroidSidebarModel,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.preferences = preferences
        self.overlay = overlay
        self.model = model
        self.simulatorModel = simulatorModel
        self.androidModel = androidModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    deinit {
        for entry in loops.values { entry.task.cancel() }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        view = root
        follow()
        followCollapse()
        followReports()
        followFontSpec()
    }

    // MARK: - Which surface is up

    /// The one observation that decides what is mounted, re-arming itself on every read it took.
    ///
    /// Everything the four surfaces switch on is read INSIDE the tracking block — the selected tab, the
    /// workbench's phase, the two device phases, the active pane and its project key, the admitted-
    /// projects set. A read left outside is a surface that stops updating for one reason only, which is
    /// the failure mode that survives every test.
    private func follow() {
        var plan = SurfacePlan.empty
        withObservationTracking {
            plan = self.plan()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        apply(plan)
    }

    /// What should be on screen and which loops should be running, as ONE value.
    ///
    /// A plan rather than four `if`s because the loops and the mount have to be decided from the same
    /// read: a mount that switched to Simulators while the loop decision still said Code is a surface
    /// polling for the tab beside it.
    private func plan() -> SurfacePlan {
        switch chrome.panelSurface {
        case .code:
            let root = activeProjectRoot
            let state = CodePanelPresentation.workbench(
                phase: model.phase,
                activeProjectRoot: root,
                openedProjects: chrome.openedCodeProjects,
                awaitingProjectKey: awaitingProjectKey,
            )
            // The poll runs for an ADMITTED root only. Behind the gate there is nothing to ensure, and
            // polling there would boot the very thing the gate exists to defer.
            let polls = root.map(chrome.openedCodeProjects.contains) ?? false
            return SurfacePlan(
                code: state,
                codePollKey: polls ? root.map { "\($0)#\(model.generation)" } : nil,
            )
        case .simulators:
            return SurfacePlan(
                device: CodePanelPresentation.simulators(simulatorModel.phase),
                which: .simulators,
                ensureKey: "\(simulatorModel.generation)",
                watchKey: CodePanelPresentation.readyKey(simulatorModel.phase),
            )
        case .android:
            return SurfacePlan(
                device: CodePanelPresentation.android(androidModel.phase),
                which: .android,
                ensureKey: "\(androidModel.generation)",
                watchKey: CodePanelPresentation.readyKey(androidModel.phase),
            )
        case .desktop:
            return SurfacePlan(desktop: CodePanelPresentation.desktop)
        }
    }

    /// Mount what the plan asks for and run exactly the loops it names.
    private func apply(_ plan: SurfacePlan) {
        mount(plan)
        keyed(.codePoll, on: plan.codePollKey) { [weak self] in await self?.runCodePoll() }
        keyed(.simulatorEnsure, on: plan.which == .simulators ? plan.ensureKey : nil) { [weak self] in
            await self?.simulatorModel.poll(
                host: { [connection = self?.connection] in connection?.target.host ?? "" },
                ensure: { [store = self?.store] in
                    await store?.firstConnectedMetadataClient?.ensureSimulatorServer()
                },
            )
        }
        keyed(.simulatorWatch, on: plan.which == .simulators ? plan.watchKey : nil) { [weak self] in
            await self?.simulatorModel.watchDevices()
        }
        keyed(.androidEnsure, on: plan.which == .android ? plan.ensureKey : nil) { [weak self] in
            await self?.androidModel.poll(
                host: { [connection = self?.connection] in connection?.target.host ?? "" },
                ensure: { [store = self?.store] in
                    await store?.firstConnectedMetadataClient?.ensureAndroidBridge()
                },
            )
        }
        keyed(.androidWatch, on: plan.which == .android ? plan.watchKey : nil) { [weak self] in
            await self?.androidModel.watchDevices()
        }
    }

    // MARK: - The mount

    /// Swap the mounted surface if — and only if — the plan describes a different one.
    ///
    /// ⚠️ THE WORKBENCH'S KEY IS ITS ROOT AND URL, NEVER ITS VEIL. A key that folded in the load state
    /// would remount the pooled webview when the first paint landed, which unparents a live page
    /// mid-navigation to hand it straight back.
    private func mount(_ plan: SurfacePlan) {
        let key = plan.identity
        guard key != mountedKey else { return }
        mountedKey = key

        if let child = mountedChild {
            child.view.removeFromSuperview()
            child.removeFromParent()
            mountedChild = nil
        }
        for subview in view.subviews { subview.removeFromSuperview() }
        // Leaving a device surface parks its stream. The SwiftUI original spent an `.onDisappear` on
        // this; here it is the same instant, said once for both devices.
        if plan.which != .simulators { simulatorModel.park() }
        if plan.which != .android { androidModel.park() }

        let surface = build(plan)
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if plan.which == .simulators { simulatorModel.resume() }
        if plan.which == .android { androidModel.resume() }
    }

    private func build(_ plan: SurfacePlan) -> NSView {
        if let empty = plan.desktop { return MacPanelEmptyStateView(empty) }
        if let device = plan.device {
            switch device {
            case .devices: return hostedDevices(plan.which)
            case let .waiting(label): return MacPanelWaitingView(label)
            case let .empty(reading): return MacPanelEmptyStateView(reading)
            }
        }
        switch plan.code {
        case let .gate(root):
            return MacCodeOpenGateView(projectRoot: root) { [chrome] in chrome.openCodeProject(root) }
        case let .workbench(root, url):
            return MacCodeWorkbenchView(projectRoot: root, url: url)
        case let .waiting(label):
            return MacPanelWaitingView(label)
        case let .empty(reading):
            return MacPanelEmptyStateView(reading)
        case .none:
            return NSView()
        }
    }

    /// The one seam left into `SlopDeskClientUI`, named for exactly what crosses it.
    private func hostedDevices(_ which: SurfacePlan.Device?) -> NSView {
        let controller: NSViewController = which == .android
            ? WorkspaceColumnHosts.androidSurface(model: androidModel, overlay: overlay)
            : WorkspaceColumnHosts.simulatorSurface(model: simulatorModel, overlay: overlay)
        addChild(controller)
        mountedChild = controller
        return controller.view
    }

    // MARK: - The loops

    /// `.task(id:)`, written out: cancel what was running under a different key, start the new one, and
    /// run nothing at all for a `nil` key.
    ///
    /// The identity check is what keeps it from being a restart on every observation: a plan that names
    /// the same key as the running loop leaves it strictly alone, which is the difference between a
    /// poll that settles and one that re-ensures forever.
    private func keyed(_ id: LoopID, on key: String?, run: @escaping () async -> Void) {
        guard let key else {
            loops.removeValue(forKey: id)?.task.cancel()
            return
        }
        if let running = loops[id], running.key == key { return }
        loops.removeValue(forKey: id)?.task.cancel()
        loops[id] = (key, Task { await run() })
    }

    private func runCodePoll() async {
        guard let root = activeProjectRoot else { return }
        await model.poll(
            projectRoot: root,
            host: { [connection] in connection.target.host },
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

    // MARK: - The collapse

    /// THE COLUMN'S CONTENT LEAVES BEFORE ITS WIDTH DOES (user-reported 2026-08-09: the collapse read
    /// as rough). A panel closing is a width animation, and everything standing in it — an embedded
    /// workbench, a device stage — gets re-laid-out at every intermediate width on the way out. That
    /// reflow is the roughness; it is not the slide. So the content fades first and the empty ground
    /// rides the rest of the slide out, and coming back it is the mirror, arriving as the column lands.
    /// One gesture, one clock — the same contract the titlebar strip and the rail keep.
    private func followCollapse() {
        var collapsed = false
        withObservationTracking {
            collapsed = chrome.codeSidebarCollapsed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followCollapse() }
            }
        }
        // Leaving does not wait at all; ARRIVING waits out most of the column's slide, so the content
        // lands on a column that has already arrived rather than being dragged in with it. SwiftUI
        // spelled that as `.delay(columnSlideDuration * 0.55)` on the reveal curve; AppKit has no delay
        // on an animation group, so the wait is the schedule.
        guard collapsed else {
            let delay = Slate.Motion.columnSlide.duration * Self.revealShare
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.chrome.codeSidebarCollapsed else { return }
                    self.animateAlpha(to: 1, on: Slate.Motion.reveal)
                }
            }
            return
        }
        animateAlpha(to: 0, on: Slate.Motion.fadeOut)
    }

    /// How much of the column's slide the arriving content sits out.
    private static let revealShare = 0.55

    private func animateAlpha(to alpha: CGFloat, on curve: SlateCurve) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            view.animator().alphaValue = alpha
        }
    }

    // MARK: - What the device surfaces report

    /// One card per surface, REPLACED rather than stacked (the fixed id is the same `object_id`
    /// discipline the other window-level notices keep): these are reports about ONE panel, and three of
    /// them queued behind each other would outlive the thing they describe.
    ///
    /// Here rather than on either surface, because the surfaces come and go under the message — a "no
    /// longer running" verdict sets the text and clears the selection in one write, so a listener on
    /// the stage would be torn down in the same transaction that fired it.
    private func followReports() {
        var simulator: (String?, String?) = (nil, nil)
        var android: (String?, String?) = (nil, nil)
        withObservationTracking {
            simulator = (self.simulatorModel.failure, self.simulatorModel.notice)
            android = (self.androidModel.failure, self.androidModel.notice)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followReports() }
            }
        }
        if simulator.0 != lastSimulatorReport.failure {
            announce(
                simulator.0,
                isFailure: true,
                id: CodePanelPresentation.simulatorToastID,
                subject: simulatorSubject,
            )
        }
        if simulator.1 != lastSimulatorReport.notice {
            announce(
                simulator.1,
                isFailure: false,
                id: CodePanelPresentation.simulatorToastID,
                subject: simulatorSubject,
            )
        }
        if android.0 != lastAndroidReport.failure {
            announce(
                android.0,
                isFailure: true,
                id: CodePanelPresentation.androidToastID,
                subject: androidSubject,
            )
        }
        if android.1 != lastAndroidReport.notice {
            announce(
                android.1,
                isFailure: false,
                id: CodePanelPresentation.androidToastID,
                subject: androidSubject,
            )
        }
        lastSimulatorReport = simulator
        lastAndroidReport = android
    }

    /// The device is the SUBJECT and the sentence is the detail, not the other way round. A headline is
    /// one middle-truncated line, and every one of these messages is longer than that line — put the
    /// sentence there and the reader loses its middle, which is where the verb is.
    private func announce(_ text: String?, isFailure: Bool, id: String, subject: String) {
        guard let text, !text.isEmpty else { return }
        overlay?.pushToast(Toast(
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

    // MARK: - The font the workbench reads

    /// A LIVE font-prefs change while the panel is open re-syncs immediately (the workbench's settings
    /// watcher applies it without a reload). The ensure round below covers the panel-open path; this
    /// covers Settings edits mid-session. Best-effort, reply ignored.
    private func followFontSpec() {
        var spec: MetadataCodec.CodeFontSpec?
        withObservationTracking {
            spec = self.preferences.map { CodeFontSync.spec(terminal: $0.terminal) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followFontSpec() }
            }
        }
        guard let spec, spec != Self.lastPushedFontSpec,
              let client = store.firstConnectedMetadataClient
        else { return }
        // Records the push too, so the next ensure round does not re-send what just landed.
        Self.lastPushedFontSpec = spec
        Task { await client.syncCodeFont(spec) }
    }

    /// One ensure round: verb 18 through whichever pane carries a live metadata channel (resolved per
    /// call, like the host-info/vitals fetchers — survives pane churn/reconnects). `nil` when no pane is
    /// connected (→ `.offline`, and the loop keeps polling). A round that reaches a host which HAS
    /// code-server also pushes the client's terminal-font spec (verb 20) — the seed has to land before
    /// the workbench reads its settings, so the push rides the starting rounds rather than waiting for
    /// `.ready`. An old host's `.unsupportedVerb` is silently ignored.
    ///
    /// Two things it deliberately does NOT do. It does not push to an `.unavailable` host: the poll
    /// keeps running every ~3.6 s while the panel is open, and patching a settings file for a workbench
    /// that will never boot is pure churn. And it does not re-push a spec identical to the last one it
    /// sent — the host no-ops such a write, but the round trip still occupies the metadata queue behind
    /// real work.
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
    private static var lastPushedFontSpec: MetadataCodec.CodeFontSpec?

    // MARK: - What the panel resolves the focus to

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the cwd
    /// fallback the sidebar sections tolerate. Ensuring on the transient pre-push cwd spawns a
    /// code-server for a root the project does not have (observed: the shell's start directory vs the
    /// git toplevel — two Node processes for one project, one stranded).
    private var activeProjectRoot: String? {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the focused pane already has a SECTION identity (the cwd fallback) but no host-pushed
    /// key yet — the first push is in flight, so a brief waiting surface beats the no-project
    /// placeholder. The mirror write re-fires the observation the moment the key lands.
    private var awaitingProjectKey: Bool {
        guard let pane = store.tree.activeSession?.activeTab?.activePane,
              activeProjectRoot == nil else { return false }
        return store.paneProjectKey(pane) != nil
    }
}

// MARK: - The plan

/// What one read of the observed state says should be on screen, and which loops should be running.
private struct SurfacePlan {
    enum Device { case simulators, android }

    var code: CodePanelWorkbenchState?
    var codePollKey: String?
    var device: DevicePanelSurfaceState?
    var which: Device?
    var ensureKey: String?
    var watchKey: String?
    var desktop: PanelEmptyState?

    static let empty = Self()

    /// What makes two plans the SAME MOUNT. Deliberately not `Equatable` over the whole struct: the
    /// loop keys change without the surface changing (a reload bump keeps the workbench up), and
    /// folding them in here would remount a live page to restart a poll.
    var identity: String {
        if let desktop { return "desktop:\(desktop.title)" }
        if let device {
            let side = which == .android ? "android" : "simulators"
            switch device {
            case .devices: return "\(side):devices"
            case let .waiting(label): return "\(side):waiting:\(label)"
            case let .empty(reading): return "\(side):empty:\(reading.title)"
            }
        }
        switch code {
        case let .gate(root): return "code:gate:\(root)"
        case let .workbench(root, url): return "code:workbench:\(root)@\(url.absoluteString)"
        case let .waiting(label): return "code:waiting:\(label)"
        case let .empty(reading): return "code:empty:\(reading.title)"
        case .none: return ""
        }
    }
}
