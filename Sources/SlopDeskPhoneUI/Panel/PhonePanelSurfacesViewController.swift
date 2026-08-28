// PhonePanelSurfacesViewController — the RIGHT panel's four surfaces, on the PHONE (docs/62 stage D).
//
// The workbench (code-server in a pooled `WKWebView`), the host's iOS Simulators, its Android devices,
// and the announced-but-empty Desktop. The bar of tabs over them is this controller's SIBLING under
// ``PhonePanelViewController``; what is here is the surfaces and the host conversations that keep them
// alive.
//
// WHAT EACH SURFACE SAYS IS NOT HERE — it is ``CodePanelPresentation``, one target down, because the
// Mac draws the same four surfaces on its own layout and the words are not a fact about either drawing.
// What IS here is every part of the answer that is a framework: which `UIView` a state mounts, and —
// the load-bearing half — the LIFETIME of the loops.
//
// ## The loops, which are the reason this file is not a switch statement
//
// The deleted SwiftUI hung five `.task(id:)`s off the surfaces and got their whole lifecycle for free:
// a surface leaving cancelled its loops, and an id change restarted them. UIKit gives none of that, so
// the rule is written out — ``keyed(_:on:run:)`` below IS that `.task(id:)`, and every surface swap
// cancels what it owned. Getting it wrong is not a crash: it is a host encoder and two sockets left
// running for a panel nobody can see, which is exactly the bill ``SimulatorSidebarModel/park()`` exists
// to stop, or a poll that never restarts after a project switch and a panel stuck on a spinner.
//
// The three past bugs the deleted file documented survive as three properties of the plan below, and
// they are the reason a PLAN exists rather than four `if`s:
//
//   1. **The poll task is OUTSIDE the workbench switch.** The four workbench states are the phases the
//      poll itself moves through, so a task per branch would cancel and restart the loop on every
//      transition it caused.
//   2. **The ensure and the device watch are on SEPARATE restart keys.** Folded into one loop, the
//      list's refresh rate would be tied to the server-boot retry rate, and those want opposite
//      cadences.
//   3. **Park on the way out, resume on the way in.** Without the pair, leaving the tab strands a host
//      encoder and two websockets.
//
// ## What this controller does NOT own
//
// The three models. They belong to ``PhonePanelViewController``, which belongs to a presentation the
// reader dismisses and re-opens — and a panel that re-listed every device and re-booted every stream on
// each open would pay the parking rules' bill in the other direction. The Mac's column owns them for
// the mirror-image reason (its strip's reload plate stands outside this tree), and the models
// themselves are one target further down again, held by whatever outlives the surface.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhonePanelSurfacesViewController: UIViewController {
    private let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// The live preferences store — the terminal font prefs the panel pushes host-side (verb 20) so the
    /// editor reads like the terminal beside it.
    private let preferences: PreferencesStore?
    /// Where a device surface's reports go — the panel's own notification stack, so the panel speaks in
    /// the same card as everything else that has something to say.
    private let overlay: OverlayCoordinator?

    /// The three surface models, owned by ``PhonePanelViewController`` because they outlive this tree.
    private let model: CodeSidebarModel
    private let simulatorModel: SimulatorSidebarModel
    private let androidModel: AndroidSidebarModel

    /// What is mounted, and under which identity. The identity is what makes an observation callback
    /// that changed nothing cost nothing — a surface rebuilt on every store write would tear down the
    /// workbench several times a second.
    private var mountedKey = ""
    private var mountedChild: UIViewController?
    private var mountedWorkbench: PhoneCodeWorkbenchView?

    /// The five loops, by the key that owns each. A `nil` key means "no loop should be running".
    private var loops: [LoopID: (key: String, task: Task<Void, Never>)] = [:]

    /// The last text each device model reported, so an observation that re-fires without a new report
    /// does not push the same card again.
    private var lastSimulatorReport: (failure: String?, notice: String?) = (nil, nil)
    private var lastAndroidReport: (failure: String?, notice: String?) = (nil, nil)

    /// Supersedes callbacks armed before ``teardown()``. Every model this controller follows is
    /// app-lifetime, so a dismissed panel would otherwise keep re-arming on them (docs/62 hazard 2).
    private var generation = 0

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        follow()
        followReports()
        followFontSpec()
    }

    /// Stop every loop and every observation, and park whichever device stream is live.
    ///
    /// ⚠️ CALLED FROM THE PANEL'S DISMISSAL, not from `deinit`. A `Task` holding `self` weakly still
    /// keeps a socket open, and the parking rules are what release the host encoder — waiting for the
    /// last reference to drop would leave a stream running for however long that takes.
    func teardown() {
        generation &+= 1
        for entry in loops.values { entry.task.cancel() }
        loops.removeAll()
        mountedWorkbench?.teardown()
        simulatorModel.park()
        androidModel.park()
    }

    // MARK: - Which surface is up

    /// The one observation that decides what is mounted, re-arming itself on every read it took.
    ///
    /// Everything the four surfaces switch on is read INSIDE the tracking block — the selected tab, the
    /// workbench's phase, the two device phases, the active pane and its project key, the admitted-
    /// projects set. A read left outside is a surface that stops updating for one reason only, which is
    /// the failure mode that survives every test.
    private func follow() {
        generation &+= 1
        let generation = generation
        var plan = SurfacePlan.empty
        withObservationTracking {
            plan = self.plan()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
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

        mountedWorkbench?.teardown()
        mountedWorkbench = nil
        if let child = mountedChild {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
            mountedChild = nil
        }
        for subview in view.subviews { subview.removeFromSuperview() }
        // Leaving a device surface parks its stream. The deleted SwiftUI spent an `.onDisappear` on
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

    private func build(_ plan: SurfacePlan) -> UIView {
        if let empty = plan.desktop { return PhonePanelEmptyStateView(empty) }
        if let device = plan.device {
            switch device {
            case .devices: return hostedDevices(plan.which)
            case let .waiting(label): return PhonePanelWaitingView(label)
            case let .empty(reading): return PhonePanelEmptyStateView(reading)
            }
        }
        switch plan.code {
        case let .gate(root):
            return PhoneCodeOpenGateView(projectRoot: root) { [chrome] in chrome.openCodeProject(root) }
        case let .workbench(root, url):
            let workbench = PhoneCodeWorkbenchView(
                projectRoot: root, url: url, waitingLabel: Self.workbenchVeilLabel,
            )
            mountedWorkbench = workbench
            return workbench
        case let .waiting(label):
            return PhonePanelWaitingView(label)
        case let .empty(reading):
            return PhonePanelEmptyStateView(reading)
        case .none:
            return UIView()
        }
    }

    /// The workbench veil's caption. Not a ``CodePanelPresentation`` word, and deliberately so: it is
    /// what the MOUNT says while WebKit paints, which is a state the phase machine does not have — the
    /// poll has already reached `.ready`, so there is no phase to ask about it.
    private static let workbenchVeilLabel = "Opening workbench…"

    /// The device surface for the tab that is up, as a CHILD controller rather than a bare view.
    ///
    /// Both surfaces are two depths with a drill between them, and both have to hear the panel go away
    /// to release a live mirror — a `UIView` added to a hierarchy with no controller above it never
    /// does, and the stream would run on into the tab beside it.
    private func hostedDevices(_ which: SurfacePlan.Device?) -> UIView {
        let controller: UIViewController = which == .android
            ? PhoneAndroidSurface(model: androidModel)
            : PhoneSimulatorSurface(model: simulatorModel)
        addChild(controller)
        controller.didMove(toParent: self)
        mountedChild = controller
        return controller.view
    }

    // MARK: - The loops

    /// `.task(id:)`, written out: cancel what was running under a different key, start the new one, and
    /// run nothing at all for a `nil` key.
    ///
    /// The identity check is what keeps it from being a restart on every observation: a plan that names
    /// the same key as the running loop leaves it strictly alone, which is the difference between a poll
    /// that settles and one that re-ensures forever.
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
            // The round itself is ``CodeServerEnsure``'s, below both shells: it names no view type, and
            // the font dedupe it carries is a key against ONE host-global settings file, so a static per
            // shell was two keys for one fact (docs/56 §3).
            ensure: { [store, preferences] in
                await CodeServerEnsure.round(projectRoot: $0, store: store, preferences: preferences)
            },
            // Front the remote endpoint with the loopback relay: a secure browser context (no
            // insecure-context toast) on an origin that survives respawns. On bind failure the remote
            // address rides through — the ATS arbitrary-loads exception keeps that fallback loadable.
            localize: { host, port in
                await CodeSidebarProxyPool.shared.endpoint(host: host, port: port) ?? (host, port)
            },
        )
    }

    // MARK: - What the device surfaces report

    /// One card per surface, REPLACED rather than stacked (the fixed id is the same `object_id`
    /// discipline the other window-level notices keep): these are reports about ONE panel, and three of
    /// them queued behind each other would outlive the thing they describe.
    ///
    /// Here rather than on either surface, because the surfaces come and go under the message — a "no
    /// longer running" verdict sets the text and clears the selection in one write, so a listener on the
    /// stage would be torn down in the same transaction that fired it.
    private func followReports() {
        generation &+= 1
        let generation = generation
        var simulator: (String?, String?) = (nil, nil)
        var android: (String?, String?) = (nil, nil)
        withObservationTracking {
            simulator = (self.simulatorModel.failure, self.simulatorModel.notice)
            android = (self.androidModel.failure, self.androidModel.notice)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.followReports()
                }
            }
        }
        if simulator.0 != lastSimulatorReport.failure {
            announce(
                simulator.0, isFailure: true,
                id: CodePanelPresentation.simulatorToastID, subject: simulatorSubject,
            )
        }
        if simulator.1 != lastSimulatorReport.notice {
            announce(
                simulator.1, isFailure: false,
                id: CodePanelPresentation.simulatorToastID, subject: simulatorSubject,
            )
        }
        if android.0 != lastAndroidReport.failure {
            announce(
                android.0, isFailure: true,
                id: CodePanelPresentation.androidToastID, subject: androidSubject,
            )
        }
        if android.1 != lastAndroidReport.notice {
            announce(
                android.1, isFailure: false,
                id: CodePanelPresentation.androidToastID, subject: androidSubject,
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
            // An event at a device, not an agent's lifecycle — and with no pane to jump to, so the card
            // renders as a plain notice rather than a door.
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
    /// watcher applies it without a reload). The ensure round above covers the panel-open path; this
    /// covers Settings edits mid-session. Best-effort, reply ignored.
    private func followFontSpec() {
        generation &+= 1
        let generation = generation
        var spec: MetadataCodec.CodeFontSpec?
        withObservationTracking {
            spec = self.preferences.map { CodeFontSync.spec(terminal: $0.terminal) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.followFontSpec()
                }
            }
        }
        guard let spec, spec != CodeServerEnsure.lastPushedFontSpec,
              let client = store.firstConnectedMetadataClient
        else { return }
        // Records the push too, so the next ensure round does not re-send what just landed.
        CodeServerEnsure.recordPushed(spec)
        Task { await client.syncCodeFont(spec) }
    }

    // MARK: - What the panel resolves the focus to

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the cwd
    /// fallback the sidebar sections tolerate. Ensuring on the transient pre-push cwd spawns a
    /// code-server for a root the project does not have (observed: the shell's start directory vs the
    /// git toplevel — two Node processes for one project, one stranded).
    private var activeProjectRoot: String? {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the focused pane already has a SECTION identity (the cwd fallback) but no host-pushed key
    /// yet — the first push is in flight, so a brief waiting surface beats the no-project placeholder.
    /// The mirror write re-fires the observation the moment the key lands.
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

    /// What makes two plans the SAME MOUNT. Deliberately not `Equatable` over the whole struct: the loop
    /// keys change without the surface changing (a reload bump keeps the workbench up), and folding them
    /// in here would remount a live page to restart a poll.
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
#endif
