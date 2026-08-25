import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × the automation bootstrap (docs/22 §7)

/// The `SLOPDESK_*` launch seams `slopdesk-guigate macos --connect` and `slopdesk-guigate video` drive.
///
/// One story, end to end: resolve the autoconnect shape from the environment, apply it locally so
/// the window mounts THAT and nothing else, and upload it as op 0 once there is a document to upload
/// it to.
public extension WorkspaceStore {
    /// Builds the INITIAL workspace from the automation env vars (docs/22 §7), replacing the current
    /// `workspace` and reconciling. It only sets up SHAPE + INTENT (endpoints pre-filled) — it does
    /// **not** connect or open video; the connect / autotype / video-open TRIGGER stays in the view
    /// layer, and the env-var names are fixed by `slopdesk-guigate macos` / `slopdesk-guigate video`.
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
        // Which arguments qualify and where the key ends is
        // `slopdesk_workspace::store_shape::automation_override`, which answers a BYTE offset onto
        // the `=` — so both halves either side of it are whole UTF-8 and the split cannot land
        // mid-scalar.
        for arg in arguments.dropFirst() {
            let bytes = Array(arg.utf8)
            let at = bytes.withUnsafeBufferPointer {
                slopdesk_ws_automation_override($0.baseAddress, $0.count)
            }
            guard at >= 0, at < bytes.count,
                  let key = String(bytes: bytes[..<at], encoding: .utf8),
                  let value = String(bytes: bytes[(at + 1)...], encoding: .utf8) else { continue }
            inputs[key] = value
        }
        return inputs
    }

    func bootstrapFromEnvironment(_ env: [String: String] = WorkspaceStore.automationInputs()) {
        bootstrapTree(from: env)
    }

    /// The app target from the terminal-autoconnect env vars, or `nil`.
    ///
    /// The var NAMES stay here — they are the launch seam `slopdesk-guigate macos` writes, and a
    /// spelling, not a decision. What crosses is
    /// `slopdesk_workspace::store_shape::terminal_target`: whether these two strings describe a
    /// target at all, and what port they name. An unset var and one set to nothing are the same
    /// answer, which is why the lookups default to empty rather than branching twice.
    static func terminalTarget(from env: [String: String]) -> ConnectionTarget? {
        let host = env["SLOPDESK_AUTOCONNECT_HOST"] ?? ""
        let hostBytes = Array(host.utf8)
        let portBytes = Array((env["SLOPDESK_AUTOCONNECT_PORT"] ?? "").utf8)
        var port: UInt16 = 0
        let resolved = hostBytes.withUnsafeBufferPointer { h in
            portBytes.withUnsafeBufferPointer { p in
                slopdesk_ws_terminal_target_port(h.baseAddress, h.count, p.baseAddress, p.count, &port)
            }
        }
        guard resolved else { return nil }
        return ConnectionTarget(host: host, port: port)
    }

    /// The inspector port for the app ``ConnectionTarget``, or `nil` when there is no room above the
    /// terminal port.
    ///
    /// The wire-protocol convention for a pane's inspector second channel (docs/16, docs/20 §0): the
    /// inspector's NWConnection #2 rides the **same NetBird tunnel** beside the terminal PTY, one
    /// port above it. The offset and the arithmetic that applies it are ONE decision and both live in
    /// `slopdesk_workspace::store_shape::inspector_port` — a constant spelled on this side as well
    /// would be the two-languages drift written across a single line. `-1` is the refusal, which a
    /// `UInt16` answer can never collide with.
    static func inspectorPort(for target: ConnectionTarget) -> UInt16? {
        let port = slopdesk_ws_inspector_port(target.port)
        guard port >= 0, let resolved = UInt16(exactly: port) else { return nil }
        return resolved
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
        // The same door the connect gate prefills from — one spelling of the default, asked for.
        let port = env["SLOPDESK_AUTOCONNECT_PORT"].flatMap { UInt16($0) }
            ?? slopdesk_hostd_default_port()
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
        // The window-targeted video autoconnect (`slopdesk-guigate video` serves ONE host window) boots the
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
    /// The precedence itself is `slopdesk_workspace::store_shape::BootstrapKind`: `0` the default
    /// workspace, `1` the terminal autoconnect, `2` the video one. Only the MINTING stays here,
    /// because a tree carries pane ids and those never cross.
    static func bootstrapShape(from env: [String: String]) -> BootstrapShape {
        func singleTerminal(named host: String) -> TreeWorkspace {
            let spec = PaneSpec(kind: .terminal, title: TreeWorkspaceDefaults.paneTitle)
            let session = Session.singlePane(name: host, spec: spec)
            return TreeWorkspace(sessions: [session], activeSessionID: session.id).normalized()
        }
        let video = videoTarget(from: env)
        let terminal = terminalTarget(from: env)
        switch slopdesk_ws_bootstrap_kind(video != nil, terminal != nil) {
        case 2:
            if let (target, endpoint) = video {
                return BootstrapShape(
                    tree: singleTerminal(named: target.host),
                    target: target,
                    desktop: (pane: PaneID(), video: endpoint),
                )
            }
        case 1:
            if let target = terminal {
                return BootstrapShape(tree: singleTerminal(named: target.host), target: target, desktop: nil)
            }
        default:
            break
        }
        return BootstrapShape(tree: .defaultWorkspace(), target: nil, desktop: nil)
    }
}
