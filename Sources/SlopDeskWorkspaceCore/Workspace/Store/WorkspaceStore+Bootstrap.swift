import Foundation
import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × the automation bootstrap (docs/22 §7)

/// The `SLOPDESK_*` launch seams `check-macos.sh --connect` and `check-video.sh` drive.
///
/// One story, end to end: resolve the autoconnect shape from the environment, apply it locally so
/// the window mounts THAT and nothing else, and upload it as op 0 once there is a document to upload
/// it to.
public extension WorkspaceStore {
    /// Builds the INITIAL workspace from the automation env vars (docs/22 §7), replacing the current
    /// `workspace` and reconciling. It only sets up SHAPE + INTENT (endpoints pre-filled) — it does
    /// **not** connect or open video; the connect / autotype / video-open TRIGGER stays in the view
    /// layer, and the env-var names are fixed by `check-macos.sh` / `check-video.sh`.
    ///
    /// - `SLOPDESK_AUTOCONNECT_HOST` + `SLOPDESK_AUTOCONNECT_PORT` ⇒ the app ``Workspace/connection`` target is
    ///   that host:port and pane 0 is a plain terminal (it rides the app connection).
    /// - `SLOPDESK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports + window id ⇒ the app target is that host
    ///   (+ video ports) and the remote desktop opens DETACHED, window-targeted (video takes precedence). Title
    ///   from `SLOPDESK_VIDEO_AUTOCONNECT_TITLE` if set.
    /// - neither set ⇒ the plain default single-terminal workspace.
    ///
    /// `automationInputs`: the process environment overlaid with any `KEY=VALUE` launch argument whose key
    /// begins with `SLOPDESK_`. The env vars are the canonical seam, but a GUI-session launch cannot always
    /// inject env (e.g. `open --args …` over SSH, no way to set the child's env without root); passing the
    /// same `SLOPDESK_…=value` tokens as launch arguments is the equivalent — a matching argument overrides
    /// the inherited env.
    static func automationInputs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
    ) -> [String: String] {
        var inputs = environment
        // Skip argv[0] (the executable path); a matching `SLOPDESK_…=value` argument overrides env.
        for arg in arguments.dropFirst() {
            guard arg.hasPrefix("SLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
            inputs[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
        }
        return inputs
    }

    func bootstrapFromEnvironment(_ env: [String: String] = WorkspaceStore.automationInputs()) {
        switch liveModel {
        case .tree: bootstrapTree(from: env)
        case .canvas: bootstrapCanvas(from: env)
        }
    }

    /// The app target from the terminal-autoconnect env vars, or `nil`.
    static func terminalTarget(from env: [String: String]) -> ConnectionTarget? {
        guard let host = env["SLOPDESK_AUTOCONNECT_HOST"], !host.isEmpty,
              let portStr = env["SLOPDESK_AUTOCONNECT_PORT"], let port = UInt16(portStr) else { return nil }
        return ConnectionTarget(host: host, port: port)
    }

    /// The app target + the per-pane window from the video-autoconnect env vars, or `nil`. The terminal
    /// port defaults (the video automation only specifies UDP ports); the app target carries the host +
    /// both UDP ports so the video pane rides the shared flow.
    static func videoTarget(from env: [String: String]) -> (ConnectionTarget, VideoEndpoint)? {
        guard let host = env["SLOPDESK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let mediaStr = env["SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT"], let media = UInt16(mediaStr),
              let cursorStr = env["SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT"], let cursor = UInt16(cursorStr),
              let widStr = env["SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID"], let wid = UInt32(widStr) else { return nil }
        let title = env["SLOPDESK_VIDEO_AUTOCONNECT_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Remote window"
        let port = env["SLOPDESK_AUTOCONNECT_PORT"].flatMap { UInt16($0) } ?? 7420
        let target = ConnectionTarget(host: host, port: port, mediaPort: media, cursorPort: cursor)
        return (target, VideoEndpoint(windowID: wid, title: title))
    }
}

// MARK: - The tree half

extension WorkspaceStore {
    /// The autoconnect layout one set of automation inputs describes.
    ///
    /// A value, minted once, because its pane ids are the ids the window mounts and the panes dial.
    struct BootstrapShape {
        let tree: TreeWorkspace
        /// The endpoint the pane status bar names, or `nil` when no autoconnect var was set.
        let target: ConnectionTarget?
        /// The detached desktop pane the video autoconnect owes the document, or `nil`.
        let desktop: (pane: PaneID, video: VideoEndpoint)?
    }

    /// The tree-path bootstrap: the autoconnect layout is applied LOCALLY the moment it is asked for,
    /// and uploaded as op 0 once there is a document to upload it to.
    ///
    /// Both halves matter, and the split is the whole point. The app shell calls this inside its own
    /// `init`, before a window exists and long before the workspace channel is `.live` — so the
    /// upload has to wait. The SHAPE does not: the instant that initializer returns, SwiftUI mounts
    /// the window and every leaf in it dials a PTY. A bootstrap that only armed itself would leave
    /// the store projecting the launch default it was called to replace, the window would give that
    /// default's pane a shell, and the adopt would then land a DIFFERENT pane id on top — abandoning
    /// the first shell on the host and spawning a second for one auto-connect.
    ///
    /// So the shape is minted ONCE per launch and kept (``armedBootstrapShape``). The run that
    /// finally reaches a document adopts exactly the tree the window is already showing, pane ids
    /// included, and the projection never moves off the pane that holds the PTY.
    func bootstrapTree(from env: [String: String]) {
        let shape = armedBootstrapShape ?? Self.bootstrapShape(from: env)
        if let target = shape.target { committedConnectionTarget = target }
        guard canMutate else {
            armedBootstrapShape = shape
            armedBootstrapEnvironment = env
            // The bootstrap IS this launch's layout, and a restored-tree adopt queued behind it would
            // put the tree this run exists to replace back over the autoconnect shape.
            pendingLaunchAdopt = nil
            seedWorkspaceMirror(from: shape.tree)
            reconcileTree()
            // This launch has no restored layout on offer any more, so nothing holds the panes back:
            // the bootstrap's own tree is minted here and adopted verbatim, ids included, so the
            // window's panes are the ones the host will be asked for (``panesMayDial``).
            refreshPaneDialGate()
            return
        }
        armedBootstrapEnvironment = nil
        armedBootstrapShape = nil
        pendingLaunchAdopt = nil
        refreshPaneDialGate()
        // Nothing to fold in beside the tree: an autoconnect shape is minted here, not restored, so its
        // panes have no spawn directory to carry and the host takes its own default for each.
        stageAdopt(WorkspaceTopology(tree: shape.tree))
        // The window-targeted video autoconnect (`check-video.sh` serves ONE host window) boots the
        // remote desktop the way the user gets it: a DETACHED `.desktop` pane in its own OS window —
        // video never enters the workspace tree (docs/DECISIONS.md 2026-07-23). Its pane id is minted
        // with the shape, so the deferred run asks for the same window the immediate one would have.
        if let desktop = shape.desktop {
            stage(.spawnDetachedPane, WorkspaceIntentArgs.encode(
                detachedPane: desktop.pane, kind: .desktop, video: desktop.video,
            ))
        }
        reconcileTree()
    }

    /// Resolves the tree-path bootstrap shape. Video takes precedence over the plain terminal
    /// autoconnect; neither set ⇒ the plain default single-terminal workspace.
    ///
    /// The video shape's TREE is a lone terminal exactly like the terminal shape's — the desktop pane
    /// is detached and travels as its own intent, never in the tree.
    static func bootstrapShape(from env: [String: String]) -> BootstrapShape {
        func singleTerminal(named host: String) -> TreeWorkspace {
            let session = Session.singlePane(name: host, spec: PaneSpec(kind: .terminal, title: "Terminal"))
            return TreeWorkspace(sessions: [session], activeSessionID: session.id).normalized()
        }
        if let (target, video) = videoTarget(from: env) {
            return BootstrapShape(
                tree: singleTerminal(named: target.host),
                target: target,
                desktop: (pane: PaneID(), video: video),
            )
        }
        if let target = terminalTarget(from: env) {
            return BootstrapShape(tree: singleTerminal(named: target.host), target: target, desktop: nil)
        }
        return BootstrapShape(tree: .defaultWorkspace(), target: nil, desktop: nil)
    }
}
