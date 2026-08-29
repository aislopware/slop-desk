// ClientComposition — the client's COMPOSITION ROOT, evacuated out of the view target (docs/56 §2).
//
// Everything the app is made of — the store, the connection, the preferences, the overlay coordinator,
// the folders frecency, the Agents card model, the chrome flags — is built here, once, in one `init`,
// with every closure seam between them wired. None of it draws. It lived in `SlopDeskClientApp.init()`
// only because that is where `@State` could hold it, and the moment the UI splits in two that init
// would have had to be written twice: the same 300 lines of wiring, once per platform, which is the
// failure mode `CLAUDE.md`'s one-implementation rule exists to stop.
//
// So the scene keeps exactly one job — hold this object and render it. `SlopDeskMacUI` and
// `SlopDeskPhoneUI` each build a `ClientComposition`, hand it their own layout, and differ in nothing
// else about what the app IS.
//
// THE PLATFORM SEAMS ARE SINKS, NOT `#if`s. There is no platform gate in this file. The three OS
// surfaces — a `UNUserNotification` banner for a background event, one for a long command, and the
// agent edge's cue + banner — are optional closures the platform entry point installs after `init`.
// BOTH entry points install all three now, over the one cross-platform `CommandCompletionNotifier`;
// what still differs is the actuation inside them (the Mac bounces its Dock and plays `NSSound`, the
// phone attaches a `UNNotificationSound` to the request). The toast half of each fan-out is wired HERE
// and fires on both, independently of whether a sink is installed.

import Defaults
import Foundation
import SlopDeskClient
import SlopDeskTransport
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The platform notification seams

/// One background pane event (an OSC 9/777 notice, a `slopdesk watch` finish), resolved to everything
/// an OS notification surface needs — including the two focus facts only the store can answer.
package struct BackgroundNotice: Sendable {
    /// Which per-event toggle governs this notice (the master OSC switch, or the watch-finish one).
    package let event: NotificationEvent
    /// The pane's id as a string key, so a click can route back to it.
    package let paneIDKey: String
    /// The pane's live title (already secret-masked at the toast site; the banner masks its own).
    package let paneTitle: String
    /// The notice headline, with any private marker stripped.
    package let title: String
    /// The notice body.
    package let body: String
    /// Whether the app is frontmost — the Notify-While-Foreground tri-state reads it.
    package let appActive: Bool
    /// Whether the SOURCE pane is on screen (its tab visible / its satellite key).
    package let sourcePaneVisible: Bool
}

/// A finished long-running command, resolved for the OS banner. The duration threshold is applied by
/// the sink (`CommandCompletionNotifier.notifyIfLong`), not here — the in-app toast has its own rule.
package struct LongCommandNotice: Sendable {
    package let paneIDKey: String
    package let paneTitle: String
    package let exitCode: Int32?
    package let durationMS: UInt32
    package let appActive: Bool
    package let sourcePaneVisible: Bool
}

/// One agent attention edge (needs input / finished a turn), resolved for the platform's own surfaces:
/// each platform rings its cue and posts a banner, and both read the focus facts carried here.
package struct AgentAttentionNotice: Sendable {
    package let paneIDKey: String
    /// The agent's label (e.g. "Claude").
    package let name: String
    /// `true` = blocked awaiting input; `false` = the turn finished.
    package let needsInput: Bool
    /// The host-supplied detail line, if any.
    package let detail: String?
    /// The one-sentence body an OS banner wants ("finished — refactor the reducer"). The in-app toast
    /// derives its own headline, so it takes `detail` alone.
    package let body: String
    /// Whether the user is looking at the source pane. The TOAST is suppressed when true; the SOUND is
    /// not — a focused pane is routinely one in a background window or on another display.
    package let sourcePaneFocused: Bool
    package let appActive: Bool
    package let sourcePaneVisible: Bool
}

// MARK: - The composition root

@MainActor
package final class ClientComposition {
    // MARK: What the app is made of

    /// The ONE workspace store (docs/22 §7): every pane, tab and session in this client.
    package let store: WorkspaceStore
    /// The ONE app-global connection. Every pane channel rides the shared per-host mux under it.
    package let connection: AppConnection
    /// The ONE live settings store. Built FIRST, so its apply paths run before any env flag is forced.
    package let preferences: PreferencesStore
    /// The ONE overlay coordinator — palette, cheat sheet, Open Quickly, Global Search, Peek & Reply,
    /// the toast stack and the modals.
    package let overlay: OverlayCoordinator
    /// The client-side Folders frecency, backing Open Quickly's Folders pill. Owned here because the
    /// coordinator holds it WEAKLY.
    package let folders: FolderFrecencyStore
    /// Puts the Claude Code host hooks on, without asking, on every connection.
    package let agentHooks: AgentHookEnforcer
    /// The sidebar-collapse + window-pin flags the toolbar, menu and palette all drive.
    package let chrome: WorkspaceChromeState
    /// The per-host shared-connection pool. Retained here because the store's session factory and the
    /// workspace-document channel both close over it.
    package let muxRegistry: ConnectionRegistry
    /// The target the connect gate prefills and the document cache is keyed on.
    package let seedTarget: ConnectionTarget
    /// Whether an AUTOCONNECT env var is set. Every persistence handle above is nil under automation, so
    /// a throwaway E2E shape can never overwrite the developer's real files.
    package let isAutomation: Bool

    // MARK: The platform sinks (nil = this platform installed no OS surface)

    /// The OS banner for a background pane event. Both entry points install a `CommandCompletionNotifier`
    /// poster; the sink stays optional because this layer must not depend on either of them existing.
    package var backgroundNoticeSink: ((BackgroundNotice) -> Void)?
    /// The OS banner for a finished long command.
    package var longCommandSink: ((LongCommandNotice) -> Void)?
    /// The agent edge's platform surfaces: the banner on both, plus the cue — `NSSound` on the Mac, a
    /// `UNNotificationSound` on the request on the phone, off the one `AgentSoundPolicy` verdict.
    package var agentAttentionSink: ((AgentAttentionNotice) -> Void)?

    // MARK: Build

    /// Builds the whole client and wires every seam between its parts.
    ///
    /// - Parameters:
    ///   - deviceClass: resolves the concurrent live-video ceiling. The caller reads the platform
    ///     signal (`UIDevice.userInterfaceIdiom` on iOS, `.mac` on macOS) — this layer never asks a
    ///     view framework what it is running on.
    ///   - env: the automation inputs, injectable so the launch shape is testable without `setenv`.
    package init(
        deviceClass: VideoDeviceClass,
        env: [String: String] = WorkspaceStore.automationInputs(),
    ) {
        // Build the preferences store FIRST so its apply paths run before the video pipeline / any
        // `static let` env flag is forced (folds the config file into `EnvConfig.overlay`).
        let preferences = PreferencesStore()
        self.preferences = preferences

        // Automation runs against the real Application Support dir; every persistence handle is nil
        // under automation so the throwaway autoconnect shape can never overwrite the developer's real
        // workspace.json / device-prefs.json / folders-frecency.json.
        let isAutomation = Self.hasAutomationEnvironment(env)
        self.isAutomation = isAutomation
        let persistence: WorkspacePersistence? = isAutomation ? nil : WorkspacePersistence()

        // Per-host shared-connection pool (TCP-mux): EVERY pane rides one shared `MuxNWConnection` per
        // host, each as a logical channel.
        let muxRegistry = ConnectionRegistry(makeConnection: LiveMuxConnectionFactory.makeConnection)
        self.muxRegistry = muxRegistry

        // Honour the `On Launch` general setting. `.restoreLastSession` (the default) restores the
        // persisted tree; `.newWindow` seeds a fresh single-pane session instead (`launchTree` returns
        // nil ⇒ the store uses `TreeWorkspace.defaultWorkspace()`).
        let restoredTree = WorkspacePersistence.launchTree(
            behavior: SettingsKey.onLaunch, persistence: persistence,
        )
        let devicePrefs: DevicePreferencesStore? = isAutomation ? nil : DevicePreferencesStore()
        let seedTarget = Self.launchSeedTarget(
            isAutomation: isAutomation, devicePreferences: devicePrefs, env: env,
        )
        self.seedTarget = seedTarget
        let appConnection = AppConnection(registry: muxRegistry, seed: seedTarget)
        connection = appConnection
        let store = WorkspaceStore(
            restoringTree: restoredTree,
            makeSession: WorkspaceStore.liveMakeSession(
                makeInspector: WorkspaceStore.liveMakeInspector,
                muxRegistry: muxRegistry,
                target: { appConnection.target },
            ),
            liveVideoCap: VideoCapPolicy.cap(for: deviceClass),
            persistence: persistence,
            devicePreferences: devicePrefs,
            // The last picture of this host's document (docs/45 §7.3), so a launch paints folder names
            // and respawns each pane's shell in its project directory before anything connects.
            documentCache: isAutomation ? nil : WorkspaceCacheStore(),
            cacheHostKey: DevicePreferences.hostKey(for: seedTarget),
            // Hold a closed video pane's cap slot briefly past `teardown()` so the dismantle releases
            // the stack before a same-tick sibling is admitted (avoids a transient cap+1).
            videoTeardownSettle: .milliseconds(250),
        )
        self.store = store

        // Build the client-side Folders frecency store. Under automation it points at a THROWAWAY temp
        // sidecar, on the same terms as the nil-persistence guard above.
        let folders: FolderFrecencyStore = isAutomation
            ? FolderFrecencyStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("slopdesk-automation-folders-frecency.json"))
            : FolderFrecencyStore()
        self.folders = folders

        // The single overlay coordinator, built after the store + connection so its seams can close over
        // them. It holds `folders` WEAKLY — this object is the owner.
        let overlay = OverlayCoordinator(store: store, folders: folders)
        self.overlay = overlay

        agentHooks = Self.makeAgentHooks(store: store)
        chrome = WorkspaceChromeState()

        // Everything above is now stored, so the wiring below may reference `self`.
        wireConnection()
        wireStore()
        wireNotifications()
        Self.wireWorkspaceNotices(store: store, overlay: overlay)

        // The pane status bar names the host before anything dials; the commit sink re-stamps it.
        store.committedConnectionTarget = seedTarget
        // Automation seams: only when the env vars are present do we let the bootstrap REPLACE the
        // restored workspace with the autoconnect/video shape (a normal launch restores untouched).
        if isAutomation { store.bootstrapFromEnvironment() }

        // SCREENSHOT FIXTURE ONLY (default-OFF): `SLOPDESK_TOAST_DEMO=<page>` seeds a STICKY
        // notification page at launch, because the card's glass surface is a GPU backdrop effect that
        // `ImageRenderer` cannot rasterise — the real window is the only place the shipping card can be
        // photographed.
        if let page = env["SLOPDESK_TOAST_DEMO"], !page.isEmpty {
            Self.seedDemoToasts(overlay, page: page)
        }
    }

    // MARK: - The seams between the parts

    /// The connection's four callbacks into the store, and the host-facing fetchers it polls.
    private func wireConnection() {
        // File a committed target under its `host:port` in the device preferences (so re-dialling a
        // known host restores the video ports it was reached on).
        connection.onTargetCommitted = { [weak store] target in store?.commitConnectionTarget(target) }
        // When the app-global connection (re)establishes, re-dial every pane channel stuck
        // disconnected/failed/unreachable — the leaf's connect-on-appear `.task` never re-fires under
        // keep-all-mounted, so without this fan-out a restored pane that gave up while the host was down
        // stays a dead, blank terminal behind a green pill until a manual per-pane Reconnect.
        // …and enforce the Claude Code hooks on the same edge. There is no Install button any more:
        // agent detection is what this app IS, so a host without the hooks is a host with half the
        // product dark. It runs on EVERY establish, not once, because the host on the other end of the
        // next connection is not necessarily the one from the last.
        connection.onConnectionEstablished = { [weak store, weak agentHooks = agentHooks] in
            store?.handleConnectionEstablished()
            Task { await agentHooks?.enforce() }
        }
        // Host identity: the titlebar speaks the host's NAME even when the user connected by IP. The
        // resolver asks the host itself over the metadata RPC (verb 14) through whichever pane carries a
        // live channel — resolved at CALL time, so the fetcher survives pane churn/reconnects.
        connection.hostInfoFetcher = { [weak store] in
            guard let store, let client = store.firstConnectedMetadataClient else { return nil }
            return await client.hostInfo()
        }
        // Host pulse: the footer's second line (cpu/mem) reads the machine on the other end over the
        // same metadata RPC (verb 17), resolved at call time. The connection polls it on its own clock.
        connection.hostVitalsFetcher = { [weak store] in
            guard let store, let client = store.firstConnectedMetadataClient else { return nil }
            return await client.hostVitals()
        }
        // `connectionTarget` lets the remote-window-picker modal query the live host.
        overlay.connectionTarget = { [weak connection] in connection?.target ?? .default }
    }

    /// The store's seams onto the rest of the app: the workspace document channel, the settings store,
    /// the connection gate, the font-size stepper, the frecency recorder and the local pasteboard.
    private func wireStore() {
        // The workspace-document channel (`channelClass 1`, docs/45 §5) rides the SAME shared connection
        // and holds it up on its own, so a client with every pane closed keeps rendering the rail.
        // Re-opened on every establish: the previous subscription died with the old link.
        store.installWorkspaceChannel(muxRegistry: muxRegistry, target: { [weak connection] in
            connection?.target ?? .default
        })
        store.attachCompletionSeenStore(preferences)
        // Gate the scene-level "Reconnect Pane" command on the app being connected.
        store.isAppConnected = { [weak connection] in
            if case .connected = connection?.status { return true }
            return false
        }
        // ⌘+/⌘-/⌘0 zoom the terminal via the SINGLE source of truth (`terminal.fontSize`) so the Settings
        // "Size" stepper stays in sync (the zoom rebuilds the libghostty config + reflows the PTY grid —
        // a font-SIZE change is correctly NOT grid-preserving).
        store.onFontSizeStep = { [weak preferences] step in
            switch step {
            case .increase: preferences?.increaseFontSize()
            case .decrease: preferences?.decreaseFontSize()
            case .reset: preferences?.resetFontSize()
            }
        }
        // Record a pane's cwd change into the frecency store. The store fires `onCwdVisited` ONLY when
        // the known cwd actually changes; the client owns the recording so `WorkspaceStore` stays
        // storage-agnostic, and `record(cwd:)` validates-then-stores (drops an empty / over-long path).
        store.onCwdVisited = { [weak folders] cwd in folders?.record(cwd: cwd) }
        // PASTE AS KEYSTROKES: the LIVE local-clipboard reader for the ⌥⌘V chord + the remote-GUI pane's
        // paste menu. Reads the CURRENT pasteboard (not the up-to-1s-stale ring head), so it works even
        // when clipboard-history recording is off. Through ``ClientPasteboard/text()``, which is the
        // cross-platform door onto the same board `write(_:)` writes — under XCTest the per-process one,
        // so a test never reads the developer's clipboard.
        store.clipboardTextProvider = { ClientPasteboard.text() }
        // The ENABLEMENT half of the same affordance, and NOT the same call: a renderer decides whether
        // the paste item is lit on every frame, and on iOS a content read there raises the modal
        // "Allow Paste?" alert. `hasText()` discloses nothing and so is answered silently.
        store.clipboardHasTextProbe = { ClientPasteboard.hasText() }
    }

    /// The four background-event fan-outs. Each pushes the in-app toast HERE (both platforms) and hands
    /// the platform sink the same edge, resolved (nil sink = this platform has no such surface).
    private func wireNotifications() {
        // Surface background events as IN-APP toasts on BOTH platforms. A toast is in-app UI,
        // INDEPENDENT of the OS-notification setting — but it respects FOCUS: the pane the user is
        // actively looking at gets no toast (they are watching the event happen). Each toast carries a
        // stable `pane.<key>` id so a newer event for the same pane REPLACES the old one.
        store.onPaneNotification = { [weak self] paneID, paneTitle, title, body in
            guard let self else { return }
            // An `slopdesk watch` finish carries the private marker in its title — route it to
            // `.watchFinish` with the marker STRIPPED; every other explicit notification stays
            // `.explicitOSC` (the master switch).
            let (event, displayTitle) = NotificationEvent.classifyExplicit(title: title, body: body)
            // SECURITY: the toast is in-app UI, so the secret redaction the OS banner and the pane
            // title apply must ALSO run here, or an OSC 9/777 title/body carrying a token is shown
            // verbatim. Done once at the construction site (`Toast.explicitOSC`) so both platforms
            // benefit — and it is a SEPARATE application from the banner's, because a toast can be
            // pushed on a platform whose sink is unbound.
            if !store.isSourcePaneFocused(paneID) {
                overlay.pushToast(Toast.explicitOSC(paneIDRaw: paneID.raw, title: displayTitle, body: body))
            }
            backgroundNoticeSink?(BackgroundNotice(
                event: event,
                paneIDKey: paneID.raw.uuidString,
                paneTitle: paneTitle,
                title: displayTitle,
                body: body,
                appActive: store.isAppActive,
                sourcePaneVisible: store.isSourcePaneVisible(paneID),
            ))
        }
        // After an UNEXPECTED reconnect, surface WHICH kind it was — `.resumedSession` reattached the
        // same live shell (scrollback intact); `.freshShell` spawned a fresh one. Otherwise a fresh shell
        // silently drops the user's context with no signal.
        store.onSessionResumeOutcome = { [weak self] paneID, outcome in
            guard let toast = Toast.sessionResume(paneIDKey: paneID.raw.uuidString, outcome: outcome)
            else { return }
            self?.overlay.pushToast(toast)
        }
        // A NON-pane-scoped copy (palette "Copy Path", rail "Copy Window Title") lights the
        // coordinator's window-level `COPIED · N` chip — the pane-less twin of the pane copy receipt.
        store.onLocalCopy = { [weak self] text in self?.overlay.noteCopy(text) }
        // The background "your build finished" cue. FOCUS-gated like the other toasts.
        // SECURITY: `paneTitle` is the live OSC 0/2 pane title — remote/PTY-settable text (often the
        // running command line such as `mysql -pSECRET`) — so it is masked at the one construction site.
        store.onLongCommandNotify = { [weak self] paneIDKey, paneTitle, exitCode, durationMS in
            guard let self else { return }
            if !store.isSourcePaneFocused(byIDString: paneIDKey) {
                overlay.pushToast(Toast.longCommand(
                    paneIDKey: paneIDKey, paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS,
                ))
            }
            longCommandSink?(LongCommandNotice(
                paneIDKey: paneIDKey,
                paneTitle: paneTitle,
                exitCode: exitCode,
                durationMS: durationMS,
                appActive: store.isAppActive,
                sourcePaneVisible: store.isSourcePaneVisible(byIDString: paneIDKey),
            ))
        }
        wireAgentAttention()
    }

    /// The agent attention sink — the ONE per-edge fan-out to the in-app toast (both platforms) and the
    /// platform's own surfaces (macOS: the sound cue + the OS banner).
    private func wireAgentAttention() {
        store.onAgentAttention = { [weak self] paneIDKey, name, needsInput, detail in
            guard let self else { return }
            let headline = needsInput ? "needs your input" : "finished"
            let body: String = {
                guard let detail, !detail.isEmpty else { return headline }
                return "\(headline) — \(detail)"
            }()
            let sourcePaneFocused = store.isSourcePaneFocused(byIDString: paneIDKey)
            // Agent-needs-input is the highest-signal background event → `.attention`; a finish is
            // `.success`. FOCUS-gated like the OSC toast: the agent pane the user is watching announces
            // its own edge on screen. The agent `detail` is host-provided (Claude label); mask any secret
            // in it (and the name) — a card on screen archives a token as readily as a banner does.
            if !sourcePaneFocused {
                overlay.pushToast(Toast(
                    id: "pane.\(paneIDKey)",
                    flavor: needsInput ? .attention : .success,
                    // `.agent` is what earns this card the "needs input" / "is done" headline instead of
                    // a command's "finished" — flavour alone cannot tell the two apart.
                    source: .agent,
                    title: Toast.redactSecretsIfEnabled(name),
                    // The toast's detail line is the DETAIL ONLY. The derived headline already says
                    // "needs input" / "is done", so passing `body` would print the state twice on one
                    // card. The OS banner still gets the full sentence — it has no derived headline.
                    body: detail.map { Toast.redactSecretsIfEnabled($0) },
                    paneKey: paneIDKey,
                ))
            }
            agentAttentionSink?(AgentAttentionNotice(
                paneIDKey: paneIDKey,
                name: name,
                needsInput: needsInput,
                detail: detail,
                body: body,
                sourcePaneFocused: sourcePaneFocused,
                appActive: store.isAppActive,
                sourcePaneVisible: store.isSourcePaneVisible(byIDString: paneIDKey),
            ))
        }
    }

    /// The three workspace-level transient notices, wired to the overlay coordinator's chip.
    ///
    /// One idea: a layout event with no visible trace of its own gets SAID.
    private static func wireWorkspaceNotices(store: WorkspaceStore, overlay: OverlayCoordinator) {
        // Closing a tab is the workspace's most destructive ROUTINE action, and the ⇧⌘T reopen has no
        // visible affordance at the moment it matters. The store fires this only when a REOPENABLE tab
        // just landed on the LIFO, so the chip never promises an undo it can't deliver.
        store.onTabCloseRecorded = { [weak overlay] in
            overlay?.noteNotice(label: "Tab closed", keycap: "⇧⌘T", detail: "reopens")
        }
        // A teleport jump (⌘⇧U walk, palette / Open Quickly, a Global Search hit, a notification /
        // connection-alert click) swaps the whole viewport in one frame. The store fires this ONLY when
        // the landing crossed a tab/session boundary — the breadcrumb chip says where you are now.
        // SECURITY: the breadcrumb embeds OSC/PTY-settable titles → mask at the display site.
        store.onCrossTabJump = { [weak overlay] breadcrumb in
            overlay?.noteNotice(
                label: "Jumped", detail: Toast.redactSecretsIfEnabled(breadcrumb), dwell: .seconds(2.5),
            )
        }
        // The workspace belongs to the host (docs/45 §7.2), so with the document out of reach every
        // split, ⌘T, close and divider drag simply does not happen — while the window keeps rendering
        // the last layout it knows and looks entirely normal. Saying so is the difference between a host
        // that is unreachable and a UI that ignored the gesture.
        store.onLayoutChangeUnavailable = { [weak overlay] in
            overlay?.noteNotice(label: "Workspace offline", detail: "Layout is host-owned")
        }
    }

    // MARK: - Launch facts

    /// The Claude Code hook enforcer. Its seams resolve the active session's FIRST connected pane
    /// metadata façade at CALL time (not at construction — no pane is connected yet). The hooks are
    /// host-global but `MetadataClient` is one-per-pane, so any live channel suffices; with no connected
    /// pane the status seam returns `nil` and the pass concludes `.unreachable`, to be retried on the
    /// next connection.
    ///
    /// There is no uninstall seam. Nothing in the app removes the hooks — that decision lives on the
    /// host, next to the file it edits.
    private static func makeAgentHooks(store: WorkspaceStore) -> AgentHookEnforcer {
        AgentHookEnforcer(
            install: { [weak store] in
                guard let store, let client = store.firstConnectedMetadataClient else { return false }
                return await client.installAgentHooks()
            },
            refreshStatus: { [weak store] in
                guard let store, let client = store.firstConnectedMetadataClient else { return nil }
                return await client.agentHookStatus()
            },
        )
    }

    /// Promotes every `SLOPDESK_<KEY>=<VALUE>` launch argument into the process environment via `setenv`.
    ///
    /// Called by the platform entry point BEFORE building a composition, because a LaunchServices `open`
    /// sanitises the inherited env and `--args` is the only remote channel — so every env-gated knob
    /// below (and every `static let` that forces one) must see the promoted value first.
    package static func applyLaunchArgumentEnvironment() {
        for arg in CommandLine.arguments.dropFirst() {
            guard arg.hasPrefix("SLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
            let key = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            setenv(key, value, 1)
        }
    }

    /// Whether the TERMINAL autoconnect host is named — the branch that decides whether an automation
    /// launch DIALS or merely marks itself connected for a video-only run (the video host serves UDP
    /// only, with no TCP listener to reach).
    ///
    /// ⚠️ THE GATE NAME IS SPELLED HERE AND NOWHERE ELSE IN A CLIENT (docs/46). Both app delegates asked
    /// this question by typing the variable, which put one env key in two shells — the drift
    /// `shared-vocabulary-ceiling` counts (docs/56 §3) and, worse than copy, a knob that could be
    /// renamed on one platform and silently keep working on the other.
    ///
    /// It is NOT ``WorkspaceStore/terminalTarget(from:)`` `!= nil`, which is the neighbouring question
    /// and a different one: that answers "do these variables describe a dialable target", so it also
    /// requires `SLOPDESK_AUTOCONNECT_PORT` to parse. A host with an unusable port must still take the
    /// dialing branch and fail there, rather than be mistaken for a video-only launch.
    ///
    /// SET-BUT-EMPTY IS UNSET, the same rule `slopdesk_workspace::store_shape::terminal_target` states:
    /// a variable set to nothing is somebody's shell expanding an unset one.
    package static func hasTerminalAutoconnectHost(
        _ env: [String: String] = WorkspaceStore.automationInputs(),
    ) -> Bool {
        env["SLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false
    }

    /// Whether any AUTOCONNECT env var is set (gates the bootstrap + the front-on-autoconnect path).
    package static func hasAutomationEnvironment(
        _ env: [String: String] = WorkspaceStore.automationInputs(),
    ) -> Bool {
        hasTerminalAutoconnectHost(env) || env["SLOPDESK_VIDEO_AUTOCONNECT_HOST"]?.isEmpty == false
    }

    /// The connect gate's prefill, and the `host:port` the document cache is gated on.
    ///
    /// The layout is host-owned and arrives over the wire, so it names no host: the last successfully
    /// connected target is the only host memory that exists before a connection, and it is the same MRU
    /// the gate's "recent hosts" menu offers. That MRU carries the TERMINAL address only — the video
    /// ports the host was last reached on are filed per `host:port` in
    /// ``DevicePreferences/connectionByHostKey``, so the whole target comes back rather than its terminal
    /// half plus two defaults.
    private static func launchSeedTarget(
        isAutomation: Bool,
        devicePreferences: DevicePreferencesStore?,
        env: [String: String],
    ) -> ConnectionTarget {
        let seed: ConnectionTarget = isAutomation
            ? (WorkspaceStore.videoTarget(from: env)?.0 ?? WorkspaceStore.terminalTarget(from: env) ?? .default)
            : AppConnection.launchSeedTarget()
        guard let devicePreferences else { return seed }
        return devicePreferences.load().connectionTarget(seededBy: seed)
    }

    /// The `SLOPDESK_TOAST_DEMO` fixture pages. Page "1" is the four-deep greatest-hits stack (both
    /// speakers + the collapsed spine tier); pages "2"–"7" walk the WHOLE vocabulary two cards at a time,
    /// so every card photographs EXPANDED (body visible without a hover). Sticky so a screenshot never
    /// races the dwell.
    private static func seedDemoToasts(_ overlay: OverlayCoordinator, page: String) {
        func push(
            _ id: String, _ flavor: Toast.Flavor, _ source: Toast.Source,
            _ title: String, _ body: String?, headline: String? = nil,
        ) {
            overlay.pushToast(Toast(
                id: "demo.\(id)", flavor: flavor, source: source,
                title: title, body: body, autoDismiss: nil, headline: headline,
            ))
        }
        switch page {
        case "2": // the agent's happy pair
            push("input", .attention, .agent, "Claude", "slop-desk ▸ api")
            push("done", .success, .agent, "Claude", "refactor the reducer")
        case "3": // the agent's unhappy pair
            push("agentfail", .error, .agent, "Claude", "turn failed")
            push("working", .default, .agent, "Claude", "slop-desk ▸ api")
        case "4": // a long command's two exits
            push("cmdok", .success, .command, "make check", "exit 0 · 42s")
            push("cmdfail", .error, .command, "make check", "exit 1 · 42s")
        case "5": // the pass-through pair: an OSC notice and a cwd advisory
            push("osc", .default, .command, "npm run dev", "listening on :3000")
            push("advisory", .attention, .command, "cd'd on host", "may not exist there")
        case "6": // the reconnect verdicts (explicit headlines)
            push(
                "reattach", .success, .command, "Session reattached",
                "Same shell — context preserved", headline: "Session reattached",
            )
            push(
                "fresh", .attention, .command, "Reconnected to a fresh shell",
                "The previous session ended", headline: "Reconnected to a fresh shell",
            )
        case "7": // content edges: a middle-truncated command line, and the shortest possible card
            push(
                "long", .error, .command,
                "docker compose -f ./deploy/compose.prod.yaml up --build --force-recreate api",
                "exit 125 · 3s",
            )
            push("short", .success, .agent, "Claude", nil)
        default: // "1": the four-deep stack — two spine rows above two full cards
            push("osc", .default, .command, "npm run dev", "listening on :3000")
            push("cmdfail", .error, .command, "make check", "exit 1 · 42s")
            push("done", .success, .agent, "Claude", "refactor the reducer")
            push("input", .attention, .agent, "Claude", "slop-desk ▸ api")
        }
    }
}
