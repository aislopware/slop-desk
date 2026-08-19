// CodeSidebarModel — the right code panel's readiness model: polls the host's `ensureCodeServer`
// metadata RPC (verb 18) for the ACTIVE project until the host's shared code-server reports ready, then
// exposes the workbench URL the WKWebView loads. The RPC never waits (the host replies with the
// CURRENT state and spawns as a side effect — see `CodeServerManager`), so readiness is client-side
// polling by design: a cold code-server boots for multiple seconds while the metadata channel's 5s
// timeout must never be leaned on.
//
// Kept free of WKWebView so the phase machine + URL builder stay unit-testable under the hang-safety
// rule (no web/network object may be created in unit tests); the webview lives in
// `CodeSidebarWebView` (macOS-only), driven by the `ready` phase's URL.

import Foundation
import SlopDeskProtocol

/// The readiness phases the code panel renders. One value per distinct surface — the column's body
/// switches over this and nothing else.
package enum CodeSidebarPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (app offline) or a host too old to
    /// know verb 18. Keep polling: the connection may come up.
    case offline
    /// The host is booting (or probing) the project's code-server — spinner, keep polling.
    case starting
    /// No code-server binary on the host — render the install hint. Still polled (slowly): a
    /// `ThirdParty/tools/provision.sh` run mid-session is picked up without a restart.
    case unavailable
    /// The workbench is reachable — load `url` in the webview and stop polling. Carries the
    /// project root the URL was built FOR: on a project switch the column re-renders before the
    /// new poll task runs, so a `.ready` can be a stale leftover of the PREVIOUS project — and a
    /// webview minted from it would open the old folder and stick (the pool's re-load check
    /// compares host/port only, never the folder). The column mounts the webview only when this
    /// root matches the active one.
    case ready(projectRoot: String, url: URL)
}

/// The poll-loop model, one per code panel column. `@Observable` so the column re-renders on each
/// phase change; the loop itself runs inside the column's `.task(id:)` (cancelled + restarted by
/// SwiftUI whenever the active project root or the reload generation changes).
@MainActor
@Observable
package final class CodeSidebarModel {
    package init() {}

    package private(set) var phase: CodeSidebarPhase = .starting

    /// Bumped by the header's reload button — part of the column's `.task` id, so a bump cancels the
    /// settled loop and re-ensures from scratch (respawning a dead code-server).
    package private(set) var generation = 0

    package func requestReload() { generation += 1 }

    /// Poll `ensure` until `.ready` (or cancellation). `host` is read per round — the connection
    /// target can change mid-loop (a reconnect to a different host must not bake in the stale name).
    /// The not-yet-running phases re-poll fast (a boot is seconds); `unavailable`/`offline` back off —
    /// they only change on operator action (install / reconnect).
    ///
    /// `localize` rewrites a READY remote endpoint to the address the webview should actually load —
    /// the loopback-proxy hook (`CodeSidebarProxyPool`): `http://127.0.0.1:<stable port>` is a SECURE
    /// browser context (no code-server "insecure context" toast, working clipboard/crypto APIs) and a
    /// STABLE origin across code-server respawns (workbench localStorage survives). It must return
    /// the input unchanged on failure — never nil, never a trap.
    package func poll(
        projectRoot: String,
        host: @MainActor () -> String?,
        ensure: (String) async -> MetadataCodec.ServiceEndpoint?,
        localize: ((_ host: String, _ port: UInt16) async -> (host: String, port: UInt16))? = nil,
        interval: Duration = .milliseconds(900),
    ) async {
        phase = .starting
        var round = 0
        while !Task.isCancelled {
            var endpoint = await ensure(projectRoot)
            guard !Task.isCancelled else { return }
            var resolvedHost = host()
            if let localize, let remote = endpoint, remote.state == .ready, let remoteHost = resolvedHost {
                let local = await localize(remoteHost, remote.port)
                guard !Task.isCancelled else { return }
                resolvedHost = local.host
                endpoint = .init(state: .ready, port: local.port)
            }
            phase = Self.phase(for: endpoint, host: resolvedHost, projectRoot: projectRoot)
            switch phase {
            case .ready: return
            case .starting:
                // The host prewarms code-server at daemon boot, so `.starting` is normally a
                // sub-second race (panel expanded moments after a hostd restart) — the first
                // rounds poll at `interval / 3` so readiness lands within ~300 ms of the host
                // having it, then the steady cadence takes over for a genuinely cold boot.
                try? await Task.sleep(for: round < Self.rampRounds ? interval / 3 : interval)
            case .offline,
                 .unavailable: try? await Task.sleep(for: interval * 4)
            }
            round += 1
        }
    }

    /// How many `.starting` rounds poll at the fast cadence before backing off to `interval` —
    /// 8 rounds × 300 ms ≈ the head of a real code-server boot (spawn → listening measured at
    /// ~0.4–1.2 s on the host this was tuned against).
    package static let rampRounds = 8

    /// One ensure round's endpoint → the phase to render. Pure — pinned by `CodeSidebarModelTests`.
    /// A `ready` endpoint that cannot form a URL (empty host) degrades to `.offline`, never a trap.
    package static func phase(
        for endpoint: MetadataCodec.ServiceEndpoint?, host: String?, projectRoot: String,
    ) -> CodeSidebarPhase {
        guard let endpoint else { return .offline }
        switch endpoint.state {
        case .unavailable: return .unavailable
        case .starting: return .starting
        case .ready:
            guard let host, let url = folderURL(host: host, port: endpoint.port, projectRoot: projectRoot)
            else { return .offline }
            return .ready(projectRoot: projectRoot, url: url)
        }
    }

    /// The workbench URL for a ready endpoint: `http://<host>:<port>/?folder=<root>` — plain HTTP on
    /// the WireGuard mesh (no app-layer auth by invariant), `?folder=` being code-server's
    /// open-this-directory query. Built via `URLComponents` so the absolute host path is
    /// percent-encoded correctly. Pure — pinned by `CodeSidebarModelTests`.
    package static func folderURL(host: String, port: UInt16, projectRoot: String) -> URL? {
        guard !host.isEmpty, port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "folder", value: projectRoot)]
        return components.url
    }

    /// Whether the pooled webview must be re-pointed: the endpoint HOST or PORT moved (a respawned
    /// code-server lands on a fresh ephemeral port; a reconnect can change the host). The folder query
    /// is deliberately ignored — one webview is keyed per project, and the workbench rewrites its own
    /// URL as the user navigates. Pure — pinned by `CodeSidebarModelTests`.
    package static func endpointMoved(current: URL?, target: URL) -> Bool {
        guard let current else { return true }
        return current.host != target.host || current.port != target.port
    }
}
