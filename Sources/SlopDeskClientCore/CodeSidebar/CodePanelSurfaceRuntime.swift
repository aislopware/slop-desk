// CodePanelSurfaceRuntime — the right panel's surface DECISION and its five loops, once for both shells.
//
// ``CodePanelPresentation`` already owns what each of the four surfaces SAYS. This owns the other half
// of the answer that is not a drawing: which surface the observed state asks for, which loops that
// surface implies, when a device stream parks and resumes, and where a device's report goes. All of it
// was written out TWICE — `MacCodePanelSurfaces` and `PhonePanelSurfacesViewController` shared 116
// eight-line windows over seven regions, and only two of those regions were `NSView`/`UIView`
// spellings. This file is the other five, and each shell now holds ONE stored property where it held
// nine.
//
// ## The loops are the reason this is an object rather than a function
//
// The deleted SwiftUI hung five `.task(id:)`s off the surfaces and got their whole lifecycle for free:
// a surface leaving cancelled its loops, and an id change restarted them. Neither imperative framework
// gives that, so the rule is written out — ``keyed(_:on:run:)`` IS that `.task(id:)` — and it needs an
// owner with a lifetime. Getting it wrong is not a crash: it is a host encoder and two sockets left
// running for a panel nobody can see, which is exactly the bill ``SimulatorSidebarModel/park()`` exists
// to stop, or a poll that never restarts after a project switch and a panel stuck on a spinner.
//
// Three past bugs survive as three properties of the plan, and they are why a PLAN exists rather than
// four `if`s:
//
//   1. **The poll task is OUTSIDE the workbench switch.** The four workbench states are the phases the
//      poll itself moves through, so a task per branch would cancel and restart the loop on every
//      transition it caused.
//   2. **The ensure and the device watch are on SEPARATE restart keys.** Folded into one loop, the
//      list's refresh rate would be tied to the server-boot retry rate, and those want opposite
//      cadences.
//   3. **Park on the way out, resume on the way in.** Without the pair, leaving the tab strands a host
//      encoder and two websockets. It is a BRACKET here — ``swappingSurface(to:mount:)`` — rather than
//      two calls a shell makes in the right order, because the order is the rule and a shell that could
//      spell it wrong eventually would.
//
// ## What is NOT here
//
// No view type, no `#if os`. The shell keeps exactly what its framework spells: which `NSView`/`UIView`
// a plan mounts, how a child controller is parented, and the constraints that fill the panel. It calls
// ``start(mount:)`` with that swap as a closure and holds nothing else.

import Foundation
import SlopDeskDevicePanels
import SlopDeskProtocol
import SlopDeskWorkspaceCore

// MARK: - The plan

/// What one read of the observed state says should be on screen, and which loops should be running.
///
/// A plan rather than four `if`s because the loops and the mount have to be decided from the same
/// read: a mount that switched to Simulators while the loop decision still said Code is a surface
/// polling for the tab beside it.
package struct CodePanelSurfacePlan {
    package enum Device { case simulators, android }

    package var code: CodePanelWorkbenchState?
    package var codePollKey: String?
    package var device: DevicePanelSurfaceState?
    package var which: Device?
    package var ensureKey: String?
    package var watchKey: String?
    package var desktop: PanelEmptyState?

    /// What makes two plans the SAME MOUNT. Deliberately not `Equatable` over the whole struct: the
    /// loop keys change without the surface changing (a reload bump keeps the workbench up), and
    /// folding them in here would remount a live page to restart a poll.
    package var identity: String {
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

// MARK: - The runtime

/// The panel's decision, its loops and its reports — created by whatever owns the three models, held
/// by the shell that draws them.
///
/// It is the shells' ONE injected dependency. Nine `private let`s and a nine-parameter `init` were the
/// same nine lines in both targets, which is a clone with no behaviour in it at all; here the list is
/// typed once and each shell stores the box.
@MainActor
package final class CodePanelSurfaceRuntime {
    // The five a shell never touches: everything they answer is answered here.
    private let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    private let connection: AppConnection
    /// The live preferences store (nil only in previews/automation shells) — the terminal font prefs
    /// the panel pushes host-side (verb 20) so the editor reads like the terminal beside it.
    private let preferences: PreferencesStore?
    /// Where a device surface's reports go — the window's own notification stack, so the panel speaks
    /// in the same card as everything else that has something to say.
    private let overlay: OverlayCoordinator?
    private let model: CodeSidebarModel

    /// The chrome and the two device models ARE a shell's, because the surface it builds names them:
    /// the gate's button opens a project, and each device surface is handed the model it draws.
    package let chrome: WorkspaceChromeState
    /// The two device models, owned OUTSIDE this runtime: the Mac's column drives them from its
    /// strip's reload plate, and the phone's panel outlives the presentation the reader dismisses.
    package let simulatorModel: SimulatorSidebarModel
    package let androidModel: AndroidSidebarModel

    /// Which loop a key belongs to. Named rather than an array index because four of the five are
    /// paired and the pairs must not be able to cancel each other.
    private enum LoopID: CaseIterable {
        case codePoll
        case simulatorEnsure
        case simulatorWatch
        case androidEnsure
        case androidWatch
    }

    /// The five loops, by the key that owns each. A `nil` key means "no loop should be running".
    private var loops: [LoopID: (key: String, task: Task<Void, Never>)] = [:]

    /// The last text each device model reported, so an observation that re-fires without a new report
    /// does not push the same card again.
    private var lastSimulatorReport: (failure: String?, notice: String?) = (nil, nil)
    private var lastAndroidReport: (failure: String?, notice: String?) = (nil, nil)

    /// The three followings, kept only so ``teardown()`` can end them while the runtime lives on.
    private var follows: [ObservationFollow] = []

    /// The shell's swap, called before the loops the same plan names. Weak on the shell's side — see
    /// ``start(mount:)``.
    private var mount: ((CodePanelSurfacePlan) -> Void)?

    package init(
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
    }

    deinit {
        for entry in loops.values { entry.task.cancel() }
    }

    // MARK: - Starting and stopping

    /// Begin following, and take the first reading now.
    ///
    /// - Parameter mount: the shell's view swap, run BEFORE the loops the same plan names. ⚠️ Capture
    ///   the shell WEAKLY: the shell holds this runtime, so a strong capture is a cycle, and every
    ///   loop the runtime starts already outlives a single mount.
    package func start(mount: @escaping (CodePanelSurfacePlan) -> Void) {
        // Arming is not idempotent (see ``ObservationFollow``), and a second `start` is a shell that
        // reloaded its view rather than a second panel — so the earlier chains END here.
        for follow in follows { follow.stop() }
        follows.removeAll()
        self.mount = mount
        follows.append(ObservationFollow.arm(self) { runtime in
            runtime.plan()
        } apply: { runtime, plan in
            runtime.deliver(plan)
        })
        follows.append(followReports())
        follows.append(followFontSpec())
    }

    /// Stop every loop and every observation, and park whichever device stream is live.
    ///
    /// ⚠️ CALLED FROM THE PANEL'S DISMISSAL on the phone, not from `deinit`. A `Task` holding the shell
    /// weakly still keeps a socket open, and the parking rules are what release the host encoder —
    /// waiting for the last reference to drop would leave a stream running for however long that takes.
    package func teardown() {
        for follow in follows { follow.stop() }
        follows.removeAll()
        mount = nil
        for entry in loops.values { entry.task.cancel() }
        loops.removeAll()
        simulatorModel.park()
        androidModel.park()
    }

    // MARK: - Which surface is up

    /// What should be on screen and which loops should be running, as ONE value.
    ///
    /// Everything the four surfaces switch on is read HERE, inside the tracked block — the selected
    /// tab, the workbench's phase, the two device phases, the active pane and its project key, the
    /// admitted-projects set. A read left outside is a surface that stops updating for one reason only,
    /// which is the failure mode that survives every test.
    private func plan() -> CodePanelSurfacePlan {
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
            return CodePanelSurfacePlan(
                code: state,
                codePollKey: polls ? root.map { "\($0)#\(model.generation)" } : nil,
            )
        case .simulators:
            return CodePanelSurfacePlan(
                device: CodePanelPresentation.simulators(simulatorModel.phase),
                which: .simulators,
                ensureKey: "\(simulatorModel.generation)",
                watchKey: CodePanelPresentation.readyKey(simulatorModel.phase),
            )
        case .android:
            return CodePanelSurfacePlan(
                device: CodePanelPresentation.android(androidModel.phase),
                which: .android,
                ensureKey: "\(androidModel.generation)",
                watchKey: CodePanelPresentation.readyKey(androidModel.phase),
            )
        case .desktop:
            return CodePanelSurfacePlan(desktop: CodePanelPresentation.desktop)
        }
    }

    /// Mount what the plan asks for and run exactly the loops it names.
    private func deliver(_ plan: CodePanelSurfacePlan) {
        mount?(plan)
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

    // MARK: - The park/resume bracket the mount sits inside

    /// Run the shell's view swap between the two halves of the parking rule.
    ///
    /// Leaving a device surface parks its stream and arriving at one resumes it. The deleted SwiftUI
    /// spent an `.onDisappear` and an `.onAppear` on this; here it is the same instant, said once for
    /// both devices and once for both shells. It brackets rather than bookends because a shell that
    /// called the two halves itself could call one of them.
    package func swappingSurface(to plan: CodePanelSurfacePlan, mount: () -> Void) {
        if plan.which != .simulators { simulatorModel.park() }
        if plan.which != .android { androidModel.park() }
        mount()
        if plan.which == .simulators { simulatorModel.resume() }
        if plan.which == .android { androidModel.resume() }
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
            // The round itself is ``CodeServerEnsure``'s: the font dedupe it carries is a key against
            // ONE host-global settings file, so a static per shell was two keys for one fact
            // (docs/56 §3).
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
    /// longer running" verdict sets the text and clears the selection in one write, so a listener on
    /// the stage would be torn down in the same transaction that fired it.
    private func followReports() -> ObservationFollow {
        ObservationFollow.arm(self) { runtime in
            (
                simulator: (
                    failure: runtime.simulatorModel.failure,
                    notice: runtime.simulatorModel.notice,
                ),
                android: (
                    failure: runtime.androidModel.failure,
                    notice: runtime.androidModel.notice,
                ),
            )
        } apply: { runtime, reading in
            if reading.simulator.failure != runtime.lastSimulatorReport.failure {
                runtime.announce(
                    reading.simulator.failure,
                    isFailure: true,
                    id: CodePanelPresentation.simulatorToastID,
                    subject: runtime.simulatorSubject,
                )
            }
            if reading.simulator.notice != runtime.lastSimulatorReport.notice {
                runtime.announce(
                    reading.simulator.notice,
                    isFailure: false,
                    id: CodePanelPresentation.simulatorToastID,
                    subject: runtime.simulatorSubject,
                )
            }
            if reading.android.failure != runtime.lastAndroidReport.failure {
                runtime.announce(
                    reading.android.failure,
                    isFailure: true,
                    id: CodePanelPresentation.androidToastID,
                    subject: runtime.androidSubject,
                )
            }
            if reading.android.notice != runtime.lastAndroidReport.notice {
                runtime.announce(
                    reading.android.notice,
                    isFailure: false,
                    id: CodePanelPresentation.androidToastID,
                    subject: runtime.androidSubject,
                )
            }
            runtime.lastSimulatorReport = reading.simulator
            runtime.lastAndroidReport = reading.android
        }
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
    /// watcher applies it without a reload). The ensure round above covers the panel-open path; this
    /// covers Settings edits mid-session. Best-effort, reply ignored.
    private func followFontSpec() -> ObservationFollow {
        ObservationFollow.arm(self) { runtime -> MetadataCodec.CodeFontSpec? in
            runtime.preferences.map { CodeFontSync.spec(terminal: $0.terminal) }
        } apply: { runtime, spec in
            guard let spec, spec != CodeServerEnsure.lastPushedFontSpec,
                  let client = runtime.store.firstConnectedMetadataClient
            else { return }
            // Records the push too, so the next ensure round does not re-send what just landed.
            CodeServerEnsure.recordPushed(spec)
            Task { await client.syncCodeFont(spec) }
        }
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

    /// Whether the focused pane already has a SECTION identity (the cwd fallback) but no host-pushed
    /// key yet — the first push is in flight, so a brief waiting surface beats the no-project
    /// placeholder. The mirror write re-fires the observation the moment the key lands.
    private var awaitingProjectKey: Bool {
        guard let pane = store.tree.activeSession?.activeTab?.activePane,
              activeProjectRoot == nil else { return false }
        return store.paneProjectKey(pane) != nil
    }
}
