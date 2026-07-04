import AislopdeskClient
import AislopdeskProtocol
import Foundation

/// The typed façade over ``AislopdeskClient/requestMetadata(requestID:verb:payload:)`` (E4): each method
/// builds a verb's request payload, mints a correlation id from its ``MetadataRequestRegistry``, fires the
/// wire request through an injected `send` seam, awaits the reply, and decodes the opaque
/// ``WireMessage/metadataResponse(requestID:status:payload:)`` payload into the verb's
/// ``MetadataCodec`` value type. The sidebar git line, Open-Quickly, and the host-path actions drive it;
/// the inbound pump resolves it via ``resolve(requestID:status:payload:)`` (folded by ``ConnectionViewModel``).
///
/// **One per pane.** Pane identity rides the mux channel envelope, so a `MetadataClient` is bound to ONE
/// pane's ``AislopdeskClient`` channel — its `send` closure targets that channel and its cache is that
/// pane's. The directory cache makes the lazy file-tree re-expand of a collapsed node free.
///
/// **Validate-then-drop, never throws to the caller.** A non-`ok` status (notFound / error /
/// unsupportedVerb / an unknown future byte → clamped to error) returns empty/`nil`; an `ok` status whose
/// payload fails to decode (a malformed / truncated `MetadataCodec` body) is ALSO swallowed to empty/`nil`
/// — the Details Panel must never hang or crash on a hostile/garbled reply (ES-E4-5). The 5 s registry
/// timeout is the final guard for a dropped reply.
///
/// `@MainActor` (like the rest of the view-model layer); the `send` seam keeps it injectable so a unit
/// test drives the façade with a fake transport that echoes canned replies (no live socket).
@preconcurrency
@MainActor
public final class MetadataClient {
    /// Fires one metadata request on the wire. Injected so the façade is testable: production wires it to
    /// ``AislopdeskClient/requestMetadata(requestID:verb:payload:)``; a test echoes a canned reply.
    public typealias Send = @MainActor (_ requestID: UInt32, _ verb: UInt8, _ payload: Data) async -> Void

    private let send: Send
    private let registry: MetadataRequestRegistry

    /// Per-pane cache of one-level directory listings keyed by request path (empty == pane cwd). The lazy
    /// file tree re-expands a collapsed node from here instead of re-fetching; ``refresh()`` clears it.
    @ObservationIgnored private var directoryCache: [String: [MetadataCodec.DirEntry]] = [:]

    /// The most recently fetched cwd (the authoritative path the inspector writes into
    /// ``PaneSpec/lastKnownCwd``). `nil` until the first ``cwd()`` round-trip resolves `ok`.
    public private(set) var cachedCwd: String?

    public init(
        timeout: Duration = MetadataRequestRegistry.defaultTimeout,
        send: @escaping Send,
    ) {
        registry = MetadataRequestRegistry(timeout: timeout)
        self.send = send
    }

    // MARK: Inbound-pump fold + lifecycle

    /// Resolves a pending request from a `.metadataResponse` event (the ``ConnectionViewModel`` fold).
    public func resolve(requestID: UInt32, status: UInt8, payload: Data) {
        registry.resolve(requestID: requestID, status: status, payload: payload)
    }

    /// Cancels every in-flight request (each resolves to empty) — called on disconnect/teardown so no
    /// façade await strands when the session drops.
    public func cancelAll() {
        registry.cancelAll()
    }

    /// Drops the directory cache so the next listing re-fetches from the host (called by ``refresh()``).
    public func invalidateDirectoryCache() {
        directoryCache.removeAll()
    }

    // MARK: Typed verbs

    /// The pane's foreground processes (``MetadataVerb/processes``). Empty on any failure.
    public func processes() async -> [MetadataCodec.ProcessInfo] {
        let (status, payload) = await request(.processes)
        guard status == .ok else { return [] }
        return (try? MetadataCodec.decodeProcessList(payload)) ?? []
    }

    /// The pane's listening ports (``MetadataVerb/ports``). Empty on any failure (and the host returns an
    /// empty list when there are none — "No listening ports").
    public func ports() async -> [MetadataCodec.PortInfo] {
        let (status, payload) = await request(.ports)
        guard status == .ok else { return [] }
        return (try? MetadataCodec.decodePortList(payload)) ?? []
    }

    /// The pane's current working directory (``MetadataVerb/cwd``). `nil` on any failure. Caches the value
    /// into ``cachedCwd`` so the inspector can mirror it into ``PaneSpec/lastKnownCwd``.
    public func cwd() async -> String? {
        let (status, payload) = await request(.cwd)
        guard status == .ok, let path = String(data: payload, encoding: .utf8) else { return nil }
        cachedCwd = path
        return path
    }

    /// The pane cwd's git status — branch + remote + ahead/behind + changed files (``MetadataVerb/gitStatus``;
    /// `gitBranch` is subsumed here). `nil` on a query failure; a non-repo cwd resolves `ok` with
    /// ``MetadataCodec/GitStatusPayload/hasRepo`` `false`.
    public func gitStatus() async -> MetadataCodec.GitStatusPayload? {
        let (status, payload) = await request(.gitStatus)
        guard status == .ok else { return nil }
        return try? MetadataCodec.decodeGitStatus(payload)
    }

    /// The unified `git diff` of one repo-relative `file` (``MetadataVerb/gitDiff``), as raw bytes (the
    /// view renders the hunks). `nil` on any failure.
    public func gitDiff(file: String) async -> Data? {
        let (status, payload) = await request(.gitDiff, payload: Data(file.utf8))
        guard status == .ok else { return nil }
        return payload
    }

    /// One level of a host directory (``MetadataVerb/listDirectory``; empty `path` == pane cwd). Leaf names
    /// only — the caller joins them with `path`. Served from the per-pane cache when `useCache` (the lazy
    /// re-expand path); a fresh fetch repopulates the cache. Empty on any failure.
    public func listDirectory(path: String = "", useCache: Bool = true) async -> [MetadataCodec.DirEntry] {
        if useCache, let cached = directoryCache[path] { return cached }
        let (status, payload) = await request(.listDirectory, payload: Data(path.utf8))
        guard status == .ok else { return [] }
        let entries = (try? MetadataCodec.decodeDirListing(payload)) ?? []
        directoryCache[path] = entries
        return entries
    }

    /// The agent (Claude/codex/opencode) session files for a `project` (``MetadataVerb/listAgentSessions``;
    /// empty `project` == pane cwd). Empty on any failure.
    public func listAgentSessions(project: String = "") async -> [MetadataCodec.AgentSessionInfo] {
        let (status, payload) = await request(.listAgentSessions, payload: Data(project.utf8))
        guard status == .ok else { return [] }
        return (try? MetadataCodec.decodeAgentSessionList(payload)) ?? []
    }

    /// One agent session's raw transcript bytes (``MetadataVerb/readAgentSession``) — the client parses the
    /// JSONL via `AislopdeskInspector.TranscriptParser`. `nil` on any failure.
    public func readAgentSession(id: String) async -> Data? {
        let (status, payload) = await request(.readAgentSession, payload: Data(id.utf8))
        guard status == .ok else { return nil }
        return payload
    }

    /// E10 WI-7 — opens `path` in its default app / Finder ON THE HOST (``MetadataVerb/openPath``; the
    /// ⌘click action). `path` is the resolved ABSOLUTE host path. Returns `true` only on a host
    /// `.ok`; `false` for `.notFound` (the path is gone) / `.error` (open failed) / a dropped reply
    /// (the registry's 5 s timeout → `.error`). The response payload is empty (side-effect-only verb).
    public func openPath(_ path: String) async -> Bool {
        let (status, _) = await request(.openPath, payload: Data(path.utf8))
        return status == .ok
    }

    /// E10 WI-7 — reveals `path` in the HOST's Finder (``MetadataVerb/revealPath``; the ⌘⇧click
    /// action). `path` is the resolved ABSOLUTE host path. Returns `true` only on a host `.ok`; `false`
    /// for `.notFound` / `.error` / a dropped reply (timed out to `.error`). The response payload is empty.
    public func revealPath(_ path: String) async -> Bool {
        let (status, _) = await request(.revealPath, payload: Data(path.utf8))
        return status == .ok
    }

    /// E13 WI-1 — installs the aislopdesk Claude Code hooks ON THE HOST (``MetadataVerb/installAgentHooks``;
    /// the Agents settings-card "Install" action). Host-global (acts on `~/.claude/settings.json`
    /// regardless of this pane), so the request carries an EMPTY payload. Returns `true` only on a host
    /// `.ok`; `false` for `.error` (the install threw) / an unsupported verb / a dropped reply (the
    /// registry's timeout → `.error`). The response payload is empty (side-effect-only verb).
    public func installAgentHooks() async -> Bool {
        let (status, _) = await request(.installAgentHooks)
        return status == .ok
    }

    /// E13 WI-1 — uninstalls the aislopdesk Claude Code hooks ON THE HOST (``MetadataVerb/uninstallAgentHooks``;
    /// the Agents settings-card "Uninstall" action). Strips exactly our entries, leaving the user's own
    /// hooks intact. Empty request payload (host-global). Returns `true` only on a host `.ok`; `false`
    /// otherwise (timeout → `.error`). The response payload is empty.
    public func uninstallAgentHooks() async -> Bool {
        let (status, _) = await request(.uninstallAgentHooks)
        return status == .ok
    }

    /// E13 WI-1 — reports the host's aislopdesk Claude Code hooks state
    /// (``MetadataVerb/agentHookStatus``; drives the Agents card's status row). Empty request payload.
    /// The reply payload is `[installed][listenerActive]` (docs/20, queue-safety cluster 2026-07-02):
    /// byte 0 is the `settings.json` install marker; byte 1 is the LIVE bind state of the hostd hook
    /// listener — so the card can show installed-but-INACTIVE (hooks written but hostd wasn't launched
    /// with `AISLOPDESK_AGENT_HOOKS=1` → every hook exits silently) instead of a false green.
    /// Returns `nil` on ANY non-decodable outcome — a non-`.ok` status, an empty payload, an
    /// unsupported verb, or a dropped reply (timeout → `.error`) — which is what lets the card show
    /// "Connect a session to manage hooks" instead of a false "Not Installed". A missing second byte
    /// (a reply predating the listener flag) conservatively decodes `listenerActive == false` — never
    /// a false green.
    public func agentHookStatus() async -> AgentHookStatusReport? {
        let (status, payload) = await request(.agentHookStatus)
        guard status == .ok, let installedFlag = payload.first else { return nil }
        let activeFlag = payload.dropFirst().first ?? 0
        return AgentHookStatusReport(installed: installedFlag == 1, listenerActive: activeFlag == 1)
    }

    /// The host's self-reported hostname (``MetadataVerb/hostInfo``; e.g. "mac-studio.local") — the
    /// chrome's durable host identity when the user connected by IP. `nil` on any failure, INCLUDING an
    /// old host answering `.unsupportedVerb` (the caller falls back to reverse-DNS / the raw target).
    public func hostInfo() async -> String? {
        let (status, payload) = await request(.hostInfo)
        guard status == .ok, let name = String(data: payload, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    // MARK: Core round-trip

    /// The decoded `agentHookStatus` (verb 13) reply — the two flag bytes, typed (queue-safety
    /// cluster, 2026-07-02). `installed` alone is NOT "the integration works": without
    /// `listenerActive` every installed hook no-ops (`[ -z "$sock" ] && exit 0`), so the card must
    /// render installed-but-inactive with the hostd-restart instruction.
    public struct AgentHookStatusReport: Equatable, Sendable {
        /// The aislopdesk entries are present in the host's `~/.claude/settings.json`.
        public var installed: Bool
        /// The hostd hook listener socket is ACTUALLY bound (hostd launched with
        /// `AISLOPDESK_AGENT_HOOKS=1` and the bind succeeded) — hooks can flow.
        public var listenerActive: Bool

        public init(installed: Bool, listenerActive: Bool) {
            self.installed = installed
            self.listenerActive = listenerActive
        }
    }

    /// Sends `verb` + `payload`, awaits the reply, and maps the raw status byte to ``MetadataStatus``
    /// (an unknown future byte clamps to ``MetadataStatus/error`` — forward-tolerant). The registry's
    /// timeout guarantees this returns even if the reply is dropped.
    private func request(
        _ verb: MetadataVerb,
        payload: Data = Data(),
    ) async -> (status: MetadataStatus, payload: Data) {
        let id = registry.next()
        await send(id, verb.rawValue, payload)
        let (rawStatus, replyPayload) = await registry.reply(for: id)
        let status = MetadataStatus(rawValue: rawStatus) ?? .error
        return (status, replyPayload)
    }
}
